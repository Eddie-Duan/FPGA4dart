/*
	wire [C_S_AXI_DATA_WIDTH-1:0]	slv_reg0;
	wire [C_S_AXI_DATA_WIDTH-1:0]	slv_reg1;
	
	assign slv_reg0 = {6'd0, top, 6'd0, bottom};
	assign slv_reg1 = {6'd0, left, 6'd0, right};
	
	reg [C_S_AXI_DATA_WIDTH-1:0]	slv_reg2;
	reg [C_S_AXI_DATA_WIDTH-1:0]	slv_reg3;
	
	assign threshold_b = slv_reg2[9:0];
	assign threshold_g = slv_reg3[25:16];
	assign threshold_r = slv_reg3[9:0];
*/

#include <linux/ioctl.h>
#include <linux/types.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/interrupt.h>
#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/slab.h>
#include <linux/wait.h>
#include <linux/mutex.h>
#include <linux/kfifo.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/of_irq.h>
#include <linux/ktime.h>
#include <linux/math64.h>

// 设备相关定义
#define DEVICE_NAME "video_manager"
#define CLASS_NAME "dart_video"

// ioctl命令定义
#define VM_IOC_MAGIC 'x'
#define VM_SET_THRESHOLD _IOW(VM_IOC_MAGIC, 1, int[3])
#define VM_GET_THRESHOLD _IOR(VM_IOC_MAGIC, 2, int[3])
#define VM_GET_POSITION _IOR(VM_IOC_MAGIC, 3, int[4])
// 添加新的ioctl命令来获取帧率
#define VM_GET_FPS _IOR(VM_IOC_MAGIC, 4, int)

// FIFO缓冲区大小
#define FIFO_SIZE 1024

typedef struct {
    u16 threshold_r;
    u16 threshold_g;
    u16 threshold_b;
} video_manager_config_t;

typedef struct {
    u16 left;
    u16 right;
    u16 top;
    u16 bottom;
} video_manager_target_t;

// 设备结构体
typedef struct {
    struct device *dev;
    video_manager_config_t config;
    video_manager_target_t target;
    struct cdev cdev;
    struct class *class;
    dev_t dev_num;
    wait_queue_head_t read_wait;
    struct mutex mutex;
    struct kfifo position_fifo;
    unsigned char *fifo_buffer;
    int irq;
    struct tasklet_struct tasklet;
    void __iomem *regs_base;
    resource_size_t regs_size;
    u32 reg_offset_multiplier; // 寄存器偏移乘数

    struct timespec64 last_frame_time;  // 使用timespec64代替ktime_t
    u32 frame_count;
    u32 fps;
    // spinlock_t stat_lock;
} video_manager_dev_t;

// 设备文件操作函数实现
static int video_manager_open(struct inode *inode, struct file *file);
static int video_manager_release(struct inode *inode, struct file *file);
static ssize_t video_manager_read(struct file *file, char __user *buffer, size_t length, loff_t *offset);
static ssize_t video_manager_write(struct file *file, const char __user *buffer, size_t length, loff_t *offset);
static long video_manager_ioctl(struct file *file, unsigned int cmd, unsigned long arg);

// 文件操作结构体
static struct file_operations fops = {
    .open = video_manager_open,
    .read = video_manager_read,
    .write = video_manager_write,
    .release = video_manager_release,
    .unlocked_ioctl = video_manager_ioctl,
};

// 中断处理函数
static irqreturn_t video_manager_interrupt_handler(int irq, void *dev_id)
{
    // 在中断上下文中，我们调度一个tasklet来处理数据读取
    struct tasklet_struct *t = &((video_manager_dev_t *)dev_id)->tasklet;
    tasklet_schedule(t);
    return IRQ_HANDLED;
}

// 寄存器读写辅助函数
static inline u16 video_manager_read_reg(video_manager_dev_t *dev, u32 reg_offset)
{
    u16 data = 0;
    u32 offset;
    
    if (!dev || !dev->regs_base)
        return 0;
    
    // 根据偏移乘数计算实际偏移
    offset = reg_offset * dev->reg_offset_multiplier;
    
    // 检查偏移是否在映射范围内
    if (offset >= dev->regs_size) {
        printk(KERN_ERR "video_manager: Register offset 0x%x out of range (size: 0x%x)\n",
               offset, (unsigned int)dev->regs_size);
        return 0;
    }
    
    data = readw(dev->regs_base + offset);
    return data;
}

static inline void video_manager_write_reg(video_manager_dev_t *dev, u32 reg_offset, u32 data)
{
    u32 offset;
    
    if (!dev || !dev->regs_base)
        return;
    
    // 根据偏移乘数计算实际偏移
    offset = reg_offset * dev->reg_offset_multiplier;
    
    // 检查偏移是否在映射范围内
    if (offset >= dev->regs_size) {
        printk(KERN_ERR "video_manager: Register offset 0x%x out of range (size: 0x%x)\n",
               offset, (unsigned int)dev->regs_size);
        return;
    }
    
    writew(data, dev->regs_base + offset);
}

// Tasklet处理函数 - 在软中断上下文中执行
static void video_manager_tasklet_handler(unsigned long data)
{
    video_manager_dev_t *dev = (video_manager_dev_t *)data;
    video_manager_target_t pos_data;
    struct timespec64 current_time;
    s64 delta_ns;
    
    // 从中断寄存器读取位置数据
    pos_data.left = video_manager_read_reg(dev, 3);   // 对应VM_LEFT_REG
    pos_data.right = video_manager_read_reg(dev, 2);  // 对应VM_RIGHT_REG
    pos_data.top = video_manager_read_reg(dev, 1);    // 对应VM_TOP_REG
    pos_data.bottom = video_manager_read_reg(dev, 0); // 对应VM_BOTTOM_REG

    // 获取当前时间
    ktime_get_ts64(&current_time);
    
    // 每100帧计算一次FPS
    if (dev->frame_count >= 99) {
        delta_ns = timespec64_to_ns(&current_time) - 
                   timespec64_to_ns(&dev->last_frame_time);
        
        if (delta_ns > 0) {
            // 使用内核的64位除法函数
            u64 fps = (100ULL * NSEC_PER_SEC);
            do_div(fps, delta_ns);
            dev->fps = (u32)fps;
        }
        
        dev->last_frame_time = current_time;
        dev->frame_count = 0;
    }else{
        dev->frame_count++;
    }
    // spin_unlock(&dev->stat_lock);
    
    // 尝试将数据放入FIFO
    if (kfifo_in(&dev->position_fifo, &pos_data, sizeof(pos_data)) != sizeof(pos_data)) {
        // FIFO已满，丢弃最旧的数据，然后重新尝试
        video_manager_target_t dummy;
        size_t discarded;
        
        // 丢弃一个数据，并显式忽略返回值
        discarded = kfifo_out(&dev->position_fifo, &dummy, sizeof(dummy));
        (void)discarded;  // 显式忽略返回值
        
        // 再次尝试写入
        if (kfifo_in(&dev->position_fifo, &pos_data, sizeof(pos_data)) != sizeof(pos_data)) {
            // 如果仍然失败，可能FIFO大小异常，重置FIFO
            printk(KERN_WARNING "video_manager: FIFO异常，重置FIFO\n");
            kfifo_reset(&dev->position_fifo);
            kfifo_in(&dev->position_fifo, &pos_data, sizeof(pos_data));
        }
    }
    
    // 唤醒等待读取的进程
    wake_up_interruptible(&dev->read_wait);
}

// 字符设备操作函数
static int video_manager_open(struct inode *inode, struct file *file)
{
    video_manager_dev_t *dev = container_of(inode->i_cdev, video_manager_dev_t, cdev);
    file->private_data = dev;
    printk(KERN_INFO "video_manager: Device opened\n");
    return 0;
}

static int video_manager_release(struct inode *inode, struct file *file)
{
    printk(KERN_INFO "video_manager: Device closed\n");
    return 0;
}

static ssize_t video_manager_read(struct file *file, char __user *buffer, size_t length, loff_t *offset)
{
    video_manager_dev_t *dev = (video_manager_dev_t *)file->private_data;
    video_manager_target_t pos_data;
    size_t bytes_to_read;
    int ret;
    
    // 等待直到有数据可用或被信号中断
    if (file->f_flags & O_NONBLOCK) {
        if (kfifo_len(&dev->position_fifo) < sizeof(pos_data)) {
            return -EAGAIN;
        }
    } else {
        ret = wait_event_interruptible(dev->read_wait, kfifo_len(&dev->position_fifo) >= sizeof(pos_data));
        if (ret) {
            return ret;
        }
    }
    
    // 从FIFO中读取数据
    bytes_to_read = min(length, (size_t)kfifo_len(&dev->position_fifo));
    bytes_to_read = min(bytes_to_read, sizeof(pos_data));
    
    if (kfifo_out(&dev->position_fifo, &pos_data, bytes_to_read) != bytes_to_read) {
        return -EIO;
    }
    
    // 将数据复制到用户空间
    if (copy_to_user(buffer, &pos_data, bytes_to_read)) {
        return -EFAULT;
    }
    
    return bytes_to_read;
}

static ssize_t video_manager_write(struct file *file, const char __user *buffer, size_t length, loff_t *offset)
{
    // 写操作被禁用，通过ioctl设置阈值
    return -EPERM;
}

static long video_manager_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
    video_manager_dev_t *dev = (video_manager_dev_t *)file->private_data;
    int threshold_data[3];
    int position_data[4];
    int fps_data;
    
    if (_IOC_TYPE(cmd) != VM_IOC_MAGIC) {
        return -ENOTTY;
    }
    
    switch (cmd) {
    case VM_SET_THRESHOLD:
        if (copy_from_user(threshold_data, (int __user *)arg, sizeof(threshold_data))) {
            return -EFAULT;
        }
        
        mutex_lock(&dev->mutex);
        dev->config.threshold_r = (u16)threshold_data[0];
        dev->config.threshold_g = (u16)threshold_data[1];
        dev->config.threshold_b = (u16)threshold_data[2];
        
        // 将阈值写入寄存器
        video_manager_write_reg(dev, 6, dev->config.threshold_r);  // 对应VM_THRESHOLD_R_REG
        video_manager_write_reg(dev, 7, dev->config.threshold_g);  // 对应VM_THRESHOLD_G_REG
        video_manager_write_reg(dev, 4, dev->config.threshold_b);  // 对应VM_THRESHOLD_B_REG
        mutex_unlock(&dev->mutex);
        
        printk(KERN_INFO "video_manager: Thresholds updated - R:%d, G:%d, B:%d\n", 
               dev->config.threshold_r, dev->config.threshold_g, dev->config.threshold_b);
        break;
        
    case VM_GET_THRESHOLD:
        mutex_lock(&dev->mutex);
        threshold_data[0] = dev->config.threshold_r;
        threshold_data[1] = dev->config.threshold_g;
        threshold_data[2] = dev->config.threshold_b;
        mutex_unlock(&dev->mutex);
        
        if (copy_to_user((int __user *)arg, threshold_data, sizeof(threshold_data))) {
            return -EFAULT;
        }
        break;
        
    case VM_GET_POSITION:
        mutex_lock(&dev->mutex);
        position_data[0] = dev->target.left;
        position_data[1] = dev->target.right;
        position_data[2] = dev->target.top;
        position_data[3] = dev->target.bottom;
        mutex_unlock(&dev->mutex);
        
        if (copy_to_user((int __user *)arg, position_data, sizeof(position_data))) {
            return -EFAULT;
        }
        break;

    case VM_GET_FPS:
        // spin_lock(&dev->stat_lock);
        fps_data = dev->fps;
        // spin_unlock(&dev->stat_lock);
        
        if (copy_to_user((int __user *)arg, &fps_data, sizeof(fps_data))) {
            return -EFAULT;
        }
        break;
        
    default:
        return -ENOTTY;
    }
    
    return 0;
}

static void video_manager_configure(video_manager_dev_t *dev)
{
    // 初始化寄存器值
    video_manager_write_reg(dev, 6, dev->config.threshold_r);  // 对应VM_THRESHOLD_R_REG
    video_manager_write_reg(dev, 7, dev->config.threshold_g);  // 对应VM_THRESHOLD_G_REG
    video_manager_write_reg(dev, 4, dev->config.threshold_b);  // 对应VM_THRESHOLD_B_REG
}

// 平台驱动probe函数
static int video_manager_probe(struct platform_device *pdev)
{
    struct device *dev = &pdev->dev;
    video_manager_dev_t *vm_dev;
    struct resource *mem_res;
    int result;
    
    printk(KERN_INFO "video_manager: Probing platform device\n");
    
    // 分配设备结构体
    vm_dev = devm_kzalloc(dev, sizeof(video_manager_dev_t), GFP_KERNEL);
    if (!vm_dev) {
        dev_err(dev, "Failed to allocate device structure\n");
        return -ENOMEM;
    }
    
    // 保存设备指针
    vm_dev->dev = dev;
    platform_set_drvdata(pdev, vm_dev);
    
    // 初始化配置参数
    vm_dev->config.threshold_r = 200;
    vm_dev->config.threshold_g = 600;
    vm_dev->config.threshold_b = 200;
    
    // 初始化互斥锁
    mutex_init(&vm_dev->mutex);
    
    // 初始化等待队列
    init_waitqueue_head(&vm_dev->read_wait);

    // 初始化帧率统计
    // spin_lock_init(&vm_dev->stat_lock);
    ktime_get_ts64(&vm_dev->last_frame_time);
    vm_dev->frame_count = 0;
    vm_dev->fps = 0;
    
    // 初始化FIFO
    vm_dev->fifo_buffer = devm_kzalloc(dev, FIFO_SIZE, GFP_KERNEL);
    if (!vm_dev->fifo_buffer) {
        dev_err(dev, "Failed to allocate FIFO buffer\n");
        return -ENOMEM;
    }
    
    kfifo_init(&vm_dev->position_fifo, vm_dev->fifo_buffer, FIFO_SIZE);
    
    // 初始化tasklet
    tasklet_init(&vm_dev->tasklet, video_manager_tasklet_handler, (unsigned long)vm_dev);
    
    // 获取内存资源
    mem_res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
    if (!mem_res) {
        dev_err(dev, "Failed to get memory resource\n");
        return -ENXIO;
    }
    
    // 映射寄存器
    vm_dev->regs_base = devm_ioremap_resource(dev, mem_res);
    if (IS_ERR(vm_dev->regs_base)) {
        dev_err(dev, "Failed to ioremap registers\n");
        return PTR_ERR(vm_dev->regs_base);
    }
    
    vm_dev->regs_size = resource_size(mem_res);
    dev_info(dev, "Mapped registers at %pR, size: 0x%x\n", mem_res, (unsigned int)vm_dev->regs_size);
    
    // 从设备树获取寄存器偏移乘数（默认为2，即每个寄存器16位，地址递增2）
    if (of_property_read_u32(dev->of_node, "reg-offset-multiplier", &vm_dev->reg_offset_multiplier)) {
        vm_dev->reg_offset_multiplier = 2; // 默认值
    }
    dev_info(dev, "Register offset multiplier: %u\n", vm_dev->reg_offset_multiplier);
    
    // 获取中断号
    vm_dev->irq = platform_get_irq(pdev, 0);
    if (vm_dev->irq < 0) {
        dev_err(dev, "Failed to get IRQ\n");
        return vm_dev->irq;
    }
    
    dev_info(dev, "Got IRQ %d\n", vm_dev->irq);
    
    // 请求中断
    result = devm_request_irq(dev, vm_dev->irq, video_manager_interrupt_handler,
                              IRQF_SHARED, DEVICE_NAME, vm_dev);
    if (result) {
        dev_err(dev, "Failed to request IRQ %d\n", vm_dev->irq);
        return result;
    }
    
    // 注册字符设备
    result = alloc_chrdev_region(&vm_dev->dev_num, 0, 1, DEVICE_NAME);
    if (result < 0) {
        dev_err(dev, "Failed to allocate device number\n");
        return result;
    }
    
    // 初始化cdev
    cdev_init(&vm_dev->cdev, &fops);
    vm_dev->cdev.owner = THIS_MODULE;
    
    result = cdev_add(&vm_dev->cdev, vm_dev->dev_num, 1);
    if (result < 0) {
        dev_err(dev, "Failed to add character device\n");
        goto fail_cdev_add;
    }
    
    // 创建设备类
    vm_dev->class = class_create(THIS_MODULE, CLASS_NAME);
    if (IS_ERR(vm_dev->class)) {
        dev_err(dev, "Failed to create device class\n");
        result = PTR_ERR(vm_dev->class);
        goto fail_class_create;
    }
    
    // 创建设备节点
    vm_dev->dev = device_create(vm_dev->class, NULL, vm_dev->dev_num, NULL, DEVICE_NAME);
    if (IS_ERR(vm_dev->dev)) {
        dev_err(dev, "Failed to create device\n");
        result = PTR_ERR(vm_dev->dev);
        goto fail_device_create;
    }
    
    // 配置设备
    video_manager_configure(vm_dev);
    
    dev_info(dev, "video_manager: Driver initialized successfully (major=%d)\n", MAJOR(vm_dev->dev_num));
    return 0;

fail_device_create:
    class_destroy(vm_dev->class);
fail_class_create:
    cdev_del(&vm_dev->cdev);
fail_cdev_add:
    unregister_chrdev_region(vm_dev->dev_num, 1);
    return result;
}

// 平台驱动remove函数
static int video_manager_remove(struct platform_device *pdev)
{
    video_manager_dev_t *vm_dev = platform_get_drvdata(pdev);
    
    printk(KERN_INFO "video_manager: Removing platform device\n");
    
    if (vm_dev) {
        // 停止tasklet
        tasklet_kill(&vm_dev->tasklet);
        
        // 销毁设备节点和类
        device_destroy(vm_dev->class, vm_dev->dev_num);
        class_destroy(vm_dev->class);
        
        // 删除字符设备
        cdev_del(&vm_dev->cdev);
        unregister_chrdev_region(vm_dev->dev_num, 1);
        
        // 注意：中断、内存映射和缓冲区由devm_*函数自动释放
    }
    
    return 0;
}

// 设备树匹配表
static const struct of_device_id video_manager_of_ids[] = {
    { .compatible = "xlnx,video-manager-1.0" },
    { /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, video_manager_of_ids);

// 平台驱动结构体
static struct platform_driver video_manager_driver = {
    .driver = {
        .name = "video_manager",
        .owner = THIS_MODULE,
        .of_match_table = video_manager_of_ids,
    },
    .probe = video_manager_probe,
    .remove = video_manager_remove,
};

// 模块初始化和退出函数
static int __init video_manager_init(void)
{
    int result;
    
    printk(KERN_INFO "video_manager: Initializing platform driver\n");
    
    result = platform_driver_register(&video_manager_driver);
    if (result) {
        printk(KERN_ERR "video_manager: Failed to register platform driver: %d\n", result);
        return result;
    }
    
    return 0;
}

static void __exit video_manager_exit(void)
{
    printk(KERN_INFO "video_manager: Unloading platform driver\n");
    platform_driver_unregister(&video_manager_driver);
}

module_init(video_manager_init);
module_exit(video_manager_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("wps");
MODULE_DESCRIPTION("Video Manager Platform Driver with Interrupt and IPC");