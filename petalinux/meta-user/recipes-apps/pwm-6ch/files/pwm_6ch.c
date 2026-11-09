/*
 * Six-channel PWM driver for Zynq - Updated for new register layout
 * New register mapping:
 * - slv_reg0~11: 12 registers total
 * - Each channel uses 2 registers: cnt_reg (even) and cmp_reg (odd)
 * - slv_reg12: Enable register (bits 0-5 for channels 0-5)
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/fs.h>
#include <linux/device.h>
#include <linux/cdev.h>
#include <linux/uaccess.h>
#include <linux/io.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/slab.h>
#include <linux/mutex.h>

#define DRV_NAME "pwm-6ch"
#define CHANNEL_COUNT 6
#define REGISTER_COUNT 13  // 12 channel registers + 1 enable register

/* Register offsets - based on new hardware design */
#define PWM_CH_CNT_OFFSET 0x00  /* Counter Register (even registers: 0,2,4,6,8,10) */
#define PWM_CH_CMP_OFFSET 0x04  /* Compare Register (odd registers: 1,3,5,7,9,11) */
#define PWM_EN_OFFSET     0x30  /* Enable Register (slv_reg12 = offset 0x30 for 4-byte regs) */

/* Calculate register offset for each channel */
#define PWM_CNT_REG_OFFSET(ch) ((ch) * 0x08)      /* cnt_reg0=0x00, cnt_reg1=0x08, etc. */
#define PWM_CMP_REG_OFFSET(ch) (((ch) * 0x08) + 0x04)  /* cmp_reg0=0x04, cmp_reg1=0x0C, etc. */

/* Device structure */
struct pwm_6ch_dev {
    struct cdev cdev;
    struct class *class;
    struct device *device;
    struct device *dev;
    void __iomem *base;
    dev_t dev_num;
    struct mutex lock;
};

static struct pwm_6ch_dev *pwm_6ch_data;

/* Register access functions */
static inline u32 pwm_read_reg(struct pwm_6ch_dev *pwm_dev, int reg_offset)
{
    return ioread32(pwm_dev->base + reg_offset);
}

static inline void pwm_write_reg(struct pwm_6ch_dev *pwm_dev, int reg_offset, u32 value)
{
    iowrite32(value, pwm_dev->base + reg_offset);
}

/* Function to read channel counter register */
static inline u32 pwm_read_cnt_reg(struct pwm_6ch_dev *pwm_dev, int channel)
{
    return pwm_read_reg(pwm_dev, PWM_CNT_REG_OFFSET(channel));
}

/* Function to write channel counter register */
static inline void pwm_write_cnt_reg(struct pwm_6ch_dev *pwm_dev, int channel, u32 value)
{
    pwm_write_reg(pwm_dev, PWM_CNT_REG_OFFSET(channel), value);
}

/* Function to read channel compare register */
static inline u32 pwm_read_cmp_reg(struct pwm_6ch_dev *pwm_dev, int channel)
{
    return pwm_read_reg(pwm_dev, PWM_CMP_REG_OFFSET(channel));
}

/* Function to write channel compare register */
static inline void pwm_write_cmp_reg(struct pwm_6ch_dev *pwm_dev, int channel, u32 value)
{
    pwm_write_reg(pwm_dev, PWM_CMP_REG_OFFSET(channel), value);
}

/* Function to read enable register */
static inline u32 pwm_read_en_reg(struct pwm_6ch_dev *pwm_dev)
{
    return pwm_read_reg(pwm_dev, PWM_EN_OFFSET);
}

/* Function to write enable register */
static inline void pwm_write_en_reg(struct pwm_6ch_dev *pwm_dev, u32 value)
{
    pwm_write_reg(pwm_dev, PWM_EN_OFFSET, value);
}

/* Function to get/set individual channel enable bit */
static inline int pwm_get_channel_en(struct pwm_6ch_dev *pwm_dev, int channel)
{
    u32 en_reg = pwm_read_en_reg(pwm_dev);
    return (en_reg >> channel) & 0x1;
}

static inline void pwm_set_channel_en(struct pwm_6ch_dev *pwm_dev, int channel, int enable)
{
    u32 en_reg = pwm_read_en_reg(pwm_dev);
    if (enable) {
        en_reg |= (1 << channel);
    } else {
        en_reg &= ~(1 << channel);
    }
    pwm_write_en_reg(pwm_dev, en_reg);
}

/* Sysfs attribute functions for channel control */
static ssize_t channel_show(struct device *dev, struct device_attribute *attr, char *buf, int reg_type)
{
    struct pwm_6ch_dev *pwm_dev = dev_get_drvdata(dev);
    int channel = -1;
    int i;
    const char *name = attr->attr.name;
    u32 value;

    /* Parse channel number from attribute name */
    for (i = 0; i < CHANNEL_COUNT; i++) {
        char temp[20];
        snprintf(temp, sizeof(temp), "ch%d_%s", i,
                reg_type == 0 ? "arr" :  // For cnt register
                reg_type == 1 ? "cmp" :  // For cmp register
                reg_type == 2 ? "en" : "unknown"); // For enable
        if (strcmp(name, temp) == 0) {
            channel = i;
            break;
        }
    }
    
    if (channel < 0) {
        return -EINVAL;
    }
    
    mutex_lock(&pwm_dev->lock);
    if (reg_type == 0) {  // Counter/ARR register
        value = pwm_read_cnt_reg(pwm_dev, channel);
    } else if (reg_type == 1) {  // Compare register
        value = pwm_read_cmp_reg(pwm_dev, channel);
    } else if (reg_type == 2) {  // Enable register
        value = pwm_get_channel_en(pwm_dev, channel);
    } else {
        mutex_unlock(&pwm_dev->lock);
        return -EINVAL;
    }
    mutex_unlock(&pwm_dev->lock);
    
    return sprintf(buf, "%u\n", value);
}

static ssize_t channel_store(struct device *dev, struct device_attribute *attr, 
                            const char *buf, size_t count, int reg_type)
{
    struct pwm_6ch_dev *pwm_dev = dev_get_drvdata(dev);
    unsigned long value;
    int channel = -1;
    int i;
    const char *name = attr->attr.name;
    
    /* Parse channel number from attribute name */
    for (i = 0; i < CHANNEL_COUNT; i++) {
        char temp[20];
        snprintf(temp, sizeof(temp), "ch%d_%s", i,
                reg_type == 0 ? "arr" :   // For cnt register
                reg_type == 1 ? "cmp" :   // For cmp register
                reg_type == 2 ? "en" : "unknown"); // For enable
        if (strcmp(name, temp) == 0) {
            channel = i;
            break;
        }
    }
    
    if (channel < 0) {
        return -EINVAL;
    }
    
    if (kstrtol(buf, 0, &value) < 0) {
        return -EINVAL;
    }
    
    mutex_lock(&pwm_dev->lock);
    if (reg_type == 0) {  // Counter/ARR register
        pwm_write_cnt_reg(pwm_dev, channel, (u32)value);
    } else if (reg_type == 1) {  // Compare register
        pwm_write_cmp_reg(pwm_dev, channel, (u32)value);
    } else if (reg_type == 2) {  // Enable register
        pwm_set_channel_en(pwm_dev, channel, (value > 0) ? 1 : 0);
    }
    mutex_unlock(&pwm_dev->lock);
    
    return count;
}

/* ARR (Counter Register) attribute functions */
static ssize_t ch0_arr_show(struct device *dev, struct device_attribute *attr, char *buf)
{ return channel_show(dev, attr, buf, 0); }
static ssize_t ch0_arr_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{ return channel_store(dev, attr, buf, count, 0); }

static ssize_t ch1_arr_show(struct device *dev, struct device_attribute *attr, char *buf)
{ return channel_show(dev, attr, buf, 0); }
static ssize_t ch1_arr_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{ return channel_store(dev, attr, buf, count, 0); }

static ssize_t ch2_arr_show(struct device *dev, struct device_attribute *attr, char *buf)
{ return channel_show(dev, attr, buf, 0); }
static ssize_t ch2_arr_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{ return channel_store(dev, attr, buf, count, 0); }

static ssize_t ch3_arr_show(struct device *dev, struct device_attribute *attr, char *buf)
{ return channel_show(dev, attr, buf, 0); }
static ssize_t ch3_arr_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{ return channel_store(dev, attr, buf, count, 0); }

static ssize_t ch4_arr_show(struct device *dev, struct device_attribute *attr, char *buf)
{ return channel_show(dev, attr, buf, 0); }
static ssize_t ch4_arr_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{ return channel_store(dev, attr, buf, count, 0); }

static ssize_t ch5_arr_show(struct device *dev, struct device_attribute *attr, char *buf)
{ return channel_show(dev, attr, buf, 0); }
static ssize_t ch5_arr_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{ return channel_store(dev, attr, buf, count, 0); }

/* CMP (Compare Register) attribute functions */
static ssize_t ch0_cmp_show(struct device *dev, struct device_attribute *attr, char *buf)
{ return channel_show(dev, attr, buf, 1); }
static ssize_t ch0_cmp_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{ return channel_store(dev, attr, buf, count, 1); }

static ssize_t ch1_cmp_show(struct device *dev, struct device_attribute *attr, char *buf)
{ return channel_show(dev, attr, buf, 1); }
static ssize_t ch1_cmp_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{ return channel_store(dev, attr, buf, count, 1); }

static ssize_t ch2_cmp_show(struct device *dev, struct device_attribute *attr, char *buf)
{ return channel_show(dev, attr, buf, 1); }
static ssize_t ch2_cmp_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{ return channel_store(dev, attr, buf, count, 1); }

static ssize_t ch3_cmp_show(struct device *dev, struct device_attribute *attr, char *buf)
{ return channel_show(dev, attr, buf, 1); }
static ssize_t ch3_cmp_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{ return channel_store(dev, attr, buf, count, 1); }

static ssize_t ch4_cmp_show(struct device *dev, struct device_attribute *attr, char *buf)
{ return channel_show(dev, attr, buf, 1); }
static ssize_t ch4_cmp_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{ return channel_store(dev, attr, buf, count, 1); }

static ssize_t ch5_cmp_show(struct device *dev, struct device_attribute *attr, char *buf)
{ return channel_show(dev, attr, buf, 1); }
static ssize_t ch5_cmp_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{ return channel_store(dev, attr, buf, count, 1); }

/* EN (Enable Register) attribute functions */
static ssize_t ch0_en_show(struct device *dev, struct device_attribute *attr, char *buf)
{ return channel_show(dev, attr, buf, 2); }
static ssize_t ch0_en_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{ return channel_store(dev, attr, buf, count, 2); }

static ssize_t ch1_en_show(struct device *dev, struct device_attribute *attr, char *buf)
{ return channel_show(dev, attr, buf, 2); }
static ssize_t ch1_en_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{ return channel_store(dev, attr, buf, count, 2); }

static ssize_t ch2_en_show(struct device *dev, struct device_attribute *attr, char *buf)
{ return channel_show(dev, attr, buf, 2); }
static ssize_t ch2_en_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{ return channel_store(dev, attr, buf, count, 2); }

static ssize_t ch3_en_show(struct device *dev, struct device_attribute *attr, char *buf)
{ return channel_show(dev, attr, buf, 2); }
static ssize_t ch3_en_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{ return channel_store(dev, attr, buf, count, 2); }

static ssize_t ch4_en_show(struct device *dev, struct device_attribute *attr, char *buf)
{ return channel_show(dev, attr, buf, 2); }
static ssize_t ch4_en_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{ return channel_store(dev, attr, buf, count, 2); }

static ssize_t ch5_en_show(struct device *dev, struct device_attribute *attr, char *buf)
{ return channel_show(dev, attr, buf, 2); }
static ssize_t ch5_en_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{ return channel_store(dev, attr, buf, count, 2); }

/* Define sysfs attributes for each channel */
static DEVICE_ATTR_RW(ch0_arr);
static DEVICE_ATTR_RW(ch0_cmp);
static DEVICE_ATTR_RW(ch0_en);

static DEVICE_ATTR_RW(ch1_arr);
static DEVICE_ATTR_RW(ch1_cmp);
static DEVICE_ATTR_RW(ch1_en);

static DEVICE_ATTR_RW(ch2_arr);
static DEVICE_ATTR_RW(ch2_cmp);
static DEVICE_ATTR_RW(ch2_en);

static DEVICE_ATTR_RW(ch3_arr);
static DEVICE_ATTR_RW(ch3_cmp);
static DEVICE_ATTR_RW(ch3_en);

static DEVICE_ATTR_RW(ch4_arr);
static DEVICE_ATTR_RW(ch4_cmp);
static DEVICE_ATTR_RW(ch4_en);

static DEVICE_ATTR_RW(ch5_arr);
static DEVICE_ATTR_RW(ch5_cmp);
static DEVICE_ATTR_RW(ch5_en);

static struct attribute *pwm_attrs[] = {
    &dev_attr_ch0_arr.attr,
    &dev_attr_ch0_cmp.attr,
    &dev_attr_ch0_en.attr,
    
    &dev_attr_ch1_arr.attr,
    &dev_attr_ch1_cmp.attr,
    &dev_attr_ch1_en.attr,
    
    &dev_attr_ch2_arr.attr,
    &dev_attr_ch2_cmp.attr,
    &dev_attr_ch2_en.attr,
    
    &dev_attr_ch3_arr.attr,
    &dev_attr_ch3_cmp.attr,
    &dev_attr_ch3_en.attr,
    
    &dev_attr_ch4_arr.attr,
    &dev_attr_ch4_cmp.attr,
    &dev_attr_ch4_en.attr,
    
    &dev_attr_ch5_arr.attr,
    &dev_attr_ch5_cmp.attr,
    &dev_attr_ch5_en.attr,
    
    NULL
};

static struct attribute_group pwm_attr_group = {
    .attrs = pwm_attrs,
};

/* Platform driver functions */
static int pwm_6ch_probe(struct platform_device *pdev)
{
    struct resource *res;
    int ret;
    u32 en_reg_val;
    
    pwm_6ch_data = devm_kzalloc(&pdev->dev, sizeof(struct pwm_6ch_dev), GFP_KERNEL);
    if (!pwm_6ch_data) {
        return -ENOMEM;
    }
    
    pwm_6ch_data->dev = &pdev->dev;
    
    /* Get memory resource */
    res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
    if (!res) {
        dev_err(&pdev->dev, "No memory resource found\n");
        return -ENODEV;
    }
    
    /* Request and map memory region */
    pwm_6ch_data->base = devm_ioremap_resource(&pdev->dev, res);
    if (IS_ERR(pwm_6ch_data->base)) {
        dev_err(&pdev->dev, "Unable to map memory resource\n");
        return PTR_ERR(pwm_6ch_data->base);
    }
    
    dev_set_drvdata(&pdev->dev, pwm_6ch_data);
    
    /* Initialize mutex */
    mutex_init(&pwm_6ch_data->lock);
    
    /* Initialize all channels to disabled state */
    mutex_lock(&pwm_6ch_data->lock);
    pwm_write_en_reg(pwm_6ch_data, 0x0);  // Disable all channels initially
    en_reg_val = pwm_read_en_reg(pwm_6ch_data);
    mutex_unlock(&pwm_6ch_data->lock);
    
    /* Create sysfs attributes */
    ret = sysfs_create_group(&pdev->dev.kobj, &pwm_attr_group);
    if (ret) {
        dev_err(&pdev->dev, "Failed to create sysfs attributes\n");
        return ret;
    }
    
    dev_info(&pdev->dev, "Six-channel PWM driver probed successfully\n");
    dev_info(&pdev->dev, "Base address: 0x%p\n", pwm_6ch_data->base);
    dev_info(&pdev->dev, "Enable register value: 0x%08x\n", en_reg_val);
    
    return 0;
}

static int pwm_6ch_remove(struct platform_device *pdev)
{
    /* Disable all PWM channels before removal */
    mutex_lock(&pwm_6ch_data->lock);
    pwm_write_en_reg(pwm_6ch_data, 0x0);  // Disable all channels
    sysfs_remove_group(&pdev->dev.kobj, &pwm_attr_group);
    mutex_unlock(&pwm_6ch_data->lock);
    
    mutex_destroy(&pwm_6ch_data->lock);
    
    dev_info(&pdev->dev, "Six-channel PWM driver removed\n");
    return 0;
}

static const struct of_device_id pwm_6ch_dt_ids[] = {
    { .compatible = "xlnx,pwm-6ch-1.0" },
    { }
};
MODULE_DEVICE_TABLE(of, pwm_6ch_dt_ids);

static struct platform_driver pwm_6ch_driver = {
    .probe = pwm_6ch_probe,
    .remove = pwm_6ch_remove,
    .driver = {
        .name = DRV_NAME,
        .of_match_table = of_match_ptr(pwm_6ch_dt_ids),
    },
};

/* Module initialization and cleanup */
static int __init pwm_6ch_init(void)
{
    int ret;
    
    ret = platform_driver_register(&pwm_6ch_driver);
    if (ret) {
        pr_err("Failed to register PWM 6ch driver\n");
        return ret;
    }
    
    pr_info("PWM 6ch driver loaded with updated register layout\n");
    return 0;
}

static void __exit pwm_6ch_exit(void)
{
    platform_driver_unregister(&pwm_6ch_driver);
    pr_info("PWM 6ch driver unloaded\n");
}

module_init(pwm_6ch_init);
module_exit(pwm_6ch_exit);

MODULE_AUTHOR("iFlow CLI");
MODULE_DESCRIPTION("Six-channel PWM driver with updated register layout: ARR/CMP registers and enable control");
MODULE_LICENSE("GPL v2");
MODULE_VERSION("1.1");