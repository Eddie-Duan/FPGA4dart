#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <string.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <termios.h>
#include <sys/select.h>

#define VM_IOC_MAGIC 'x'
#define VM_SET_THRESHOLD _IOW(VM_IOC_MAGIC, 1, int[3])
#define VM_GET_THRESHOLD _IOR(VM_IOC_MAGIC, 2, int[3])
#define VM_GET_POSITION _IOR(VM_IOC_MAGIC, 3, int[4])
#define VM_GET_FPS _IOR(VM_IOC_MAGIC, 4, int)

// 位置数据结构
typedef struct {
    unsigned short left;
    unsigned short right;
    unsigned short top;
    unsigned short bottom;
} video_manager_target_t;

// 全局变量，用于控制程序退出
static volatile int keep_running = 1;

// 信号处理函数，处理Ctrl+C
void signal_handler(int sig) {
    if (sig == SIGINT) {
        printf("\n接收到中断信号，正在退出...\n");
        keep_running = 0;
    }
}

// 清除输入缓冲区
void clear_input_buffer() {
    int c;
    while ((c = getchar()) != '\n' && c != EOF);
}

// 获取用户输入的整数
int get_integer_input(const char *prompt, int min, int max) {
    int value;
    char input[100];
    
    while (1) {
        printf("%s [%d-%d]: ", prompt, min, max);
        if (fgets(input, sizeof(input), stdin) == NULL) {
            return min; // 默认值
        }
        
        if (sscanf(input, "%d", &value) == 1 && value >= min && value <= max) {
            return value;
        }
        
        printf("错误: 请输入 %d 到 %d 之间的整数\n", min, max);
    }
}

// 显示主菜单
void display_menu() {
    printf("\n=== 视频管理器测试程序 ===\n");
    printf("1. 设置颜色阈值\n");
    printf("2. 获取当前阈值\n");
    printf("3. 获取当前位置信息\n");
    printf("4. 实时监控位置变化\n");
    printf("5. 测试帧率 (仅显示FPS)\n");
    printf("6. 实时图形显示 (方框显示)\n");
    printf("7. 退出程序\n");
    printf("请选择操作 [1-7]: ");
}

// 显示彩色阈值设置界面
void display_threshold_ui(int current_r, int current_g, int current_b) {
    printf("\n=== 颜色阈值设置 ===\n");
    printf("当前值: R=%d, G=%d, B=%d\n", current_r, current_g, current_b);
    printf("推荐范围: R(0-1023), G(0-1023), B(0-1023)\n");
}

// 设置阈值
void set_threshold(int fd) {
    int threshold_data[3];
    int result;
    
    // 先获取当前阈值
    result = ioctl(fd, VM_GET_THRESHOLD, threshold_data);
    if (result < 0) {
        perror("获取当前阈值失败");
        return;
    }
    
    display_threshold_ui(threshold_data[0], threshold_data[1], threshold_data[2]);
    
    // 获取用户输入
    threshold_data[0] = get_integer_input("请输入红色阈值(R)", 0, 1023);
    threshold_data[1] = get_integer_input("请输入绿色阈值(G)", 0, 1023);
    threshold_data[2] = get_integer_input("请输入蓝色阈值(B)", 0, 1023);
    
    // 设置阈值
    result = ioctl(fd, VM_SET_THRESHOLD, threshold_data);
    if (result < 0) {
        perror("设置阈值失败");
        return;
    }
    
    printf("阈值设置成功: R=%d, G=%d, B=%d\n", 
           threshold_data[0], threshold_data[1], threshold_data[2]);
}

// 获取并显示当前阈值
void get_threshold(int fd) {
    int threshold_data[3];
    int result;
    
    result = ioctl(fd, VM_GET_THRESHOLD, threshold_data);
    if (result < 0) {
        perror("获取阈值失败");
        return;
    }
    
    printf("\n=== 当前颜色阈值 ===\n");
    printf("红色阈值(R):   %d\n", threshold_data[0]);
    printf("绿色阈值(G):   %d\n", threshold_data[1]);
    printf("蓝色阈值(B):   %d\n", threshold_data[2]);
    
    // 显示简单的颜色条
    printf("\n阈值图示:\n");
    printf("R: ");
    for (int i = 0; i < threshold_data[0] / 40; i++) printf("█");
    printf("\n");
    
    printf("G: ");
    for (int i = 0; i < threshold_data[1] / 40; i++) printf("█");
    printf("\n");
    
    printf("B: ");
    for (int i = 0; i < threshold_data[2] / 40; i++) printf("█");
    printf("\n");
}

// 获取并显示当前位置
void get_position(int fd) {
    int position_data[4];
    int result;
    
    result = ioctl(fd, VM_GET_POSITION, position_data);
    if (result < 0) {
        perror("获取位置失败");
        return;
    }
    
    printf("\n=== 当前目标位置 ===\n");
    printf("左边界(left):   %d 像素\n", position_data[0]);
    printf("右边界(right):  %d 像素\n", position_data[1]);
    printf("上边界(top):    %d 像素\n", position_data[2]);
    printf("下边界(bottom): %d 像素\n", position_data[3]);
    
    // 计算目标大小
    int width = position_data[1] - position_data[0];
    int height = position_data[3] - position_data[2];
    
    if (width > 0 && height > 0) {
        printf("\n目标尺寸: %d x %d 像素\n", width, height);
        printf("目标面积: %d 像素²\n", width * height);
    } else {
        printf("\n注意: 无效的目标区域\n");
    }
}

// 实时监控位置变化
void monitor_position(int fd) {
    video_manager_target_t pos;
    int result;
    time_t start_time, current_time;
    int frame_count = 0;
    float fps = 0;
    
    printf("\n=== 实时位置监控 ===\n");
    start_time = time(NULL);
    printf("开始时间: %s", ctime(&start_time));
    printf("按 Ctrl+C 停止监控\n\n");
    
    // 设置为非阻塞读取
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    
    printf("%-9s %-9s %-9s %-9s %-9s %-9s %-9s\n", 
           "帧号", "左", "右", "上", "下", "宽度", "高度");
    printf("------------------------------------------------------------\n");
    
    while (keep_running) {
        result = read(fd, &pos, sizeof(pos));
        
        if (result < 0) {
            if (errno == EAGAIN) {
                // 没有数据，短暂休眠
                usleep(10000); // 10ms
                continue;
            } else {
                perror("读取失败");
                break;
            }
        }
        
        if (result == sizeof(pos)) {
            frame_count++;
            current_time = time(NULL);
            
            // 计算FPS（每秒更新一次）
            if (difftime(current_time, start_time) >= 1.0) {
                fps = frame_count / difftime(current_time, start_time);
                start_time = current_time;
                frame_count = 0;
            }
            
            // 计算目标尺寸
            int width = pos.right - pos.left;
            int height = pos.bottom - pos.top;
            
            // 显示数据
            printf("\r%-8d %-8hu %-8hu %-8hu %-8hu %-8d %-8d FPS: %.1f",
                   frame_count, pos.left, pos.right, pos.top, pos.bottom, 
                   width, height, fps);
            fflush(stdout);
        }
    }
    
    // 恢复阻塞模式
    fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
    printf("\n\n监控结束，共收到 %d 帧数据\n", frame_count);
}

// 功能5：测试帧率（仅显示FPS）
void test_fps_only(int fd) {
    int fps;
    time_t start_time, last_update_time, current_time;
    int frame_count = 0;
    float current_fps = 0.0;
    
    printf("\n=== 帧率测试模式 ===\n");
    printf("仅显示FPS，按任意键退出\n\n");
    
    // 设置为非阻塞标准输入
    struct termios oldt, newt;
    tcgetattr(STDIN_FILENO, &oldt);
    newt = oldt;
    newt.c_lflag &= ~(ICANON | ECHO);
    tcsetattr(STDIN_FILENO, TCSANOW, &newt);
    
    time(&start_time);
    last_update_time = start_time;
    
    // printf("FPS: 0.0\n");
    
    while (keep_running) {
        // 检查是否有按键
        struct timeval tv = {0, 10000}; // 10ms超时
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(STDIN_FILENO, &fds);
        
        if (select(STDIN_FILENO + 1, &fds, NULL, NULL, &tv) > 0) {
            if (FD_ISSET(STDIN_FILENO, &fds)) {
                // 有按键，清空输入缓冲区
                char c;
                read(STDIN_FILENO, &c, 1);
                break;
            }
        }
        
        // 获取FPS
        if (ioctl(fd, VM_GET_FPS, &fps) >= 0) {
            frame_count++;
            time(&current_time);
            
            // 每秒更新一次显示
            if (difftime(current_time, last_update_time) >= 1.0) {
                current_fps = fps;
                printf("\rFPS: %.1f   ", current_fps);
                fflush(stdout);
                last_update_time = current_time;
                frame_count = 0;
            }
        }
    }
    
    // 恢复终端设置
    tcsetattr(STDIN_FILENO, TCSANOW, &oldt);
    printf("\n\n帧率测试结束\n");
}

// 功能6：实时图形显示
void realtime_graphical_display(int fd) {
    video_manager_target_t pos;
    int result;
    int screen_width = 80;   // 终端宽度
    int screen_height = 24;  // 终端高度
    int video_width = 640;   // 实际视频宽度 (0-639)
    int video_height = 400;  // 实际视频高度 (0-399)
    time_t start_time, last_update_time, current_time;
    int frame_count = 0;
    float fps = 0.0;
    
    printf("\n=== 实时图形显示模式 ===\n");
    printf("坐标范围: X:0-639, Y:0-399\n");
    printf("按任意键退出\n\n");
    
    // 设置为非阻塞标准输入
    struct termios oldt, newt;
    tcgetattr(STDIN_FILENO, &oldt);
    newt = oldt;
    newt.c_lflag &= ~(ICANON | ECHO);
    tcsetattr(STDIN_FILENO, TCSANOW, &newt);
    
    // 设置为非阻塞设备读取
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    
    time(&start_time);
    last_update_time = start_time;
    
    while (keep_running) {
        // 检查是否有按键
        struct timeval tv = {0, 50000}; // 50ms超时
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(STDIN_FILENO, &fds);
        
        if (select(STDIN_FILENO + 1, &fds, NULL, NULL, &tv) > 0) {
            if (FD_ISSET(STDIN_FILENO, &fds)) {
                // 有按键，清空输入缓冲区
                char c;
                read(STDIN_FILENO, &c, 1);
                break;
            }
        }
        
        // 读取位置数据
        result = read(fd, &pos, sizeof(pos));
        
        if (result == sizeof(pos)) {
            frame_count++;
            
            // 清屏并重置光标
            printf("\033[2J\033[H");
            
            // 显示标题和FPS
            time(&current_time);
            if (difftime(current_time, last_update_time) >= 1.0) {
                fps = frame_count / difftime(current_time, last_update_time);
                last_update_time = current_time;
                frame_count = 0;
            }
            printf("=== 实时图形显示 ===  FPS: %.1f\n\n", fps);
            
            // 计算目标框在终端中的位置和大小（比例映射）
            // 留出2个字符的边框（左右各1个字符），所以实际可用区域是screen_width-2 x screen_height-2
            int display_width = screen_width - 2;    // 78
            int display_height = screen_height - 2;  // 22
            
            // 计算缩放比例，保持宽高比
            float scale_x = (float)display_width / video_width;    // 78 / 640 = 0.121875
            float scale_y = (float)display_height / video_height;  // 22 / 400 = 0.055
            // float scale = (scale_x < scale_y) ? scale_x : scale_y; // 使用较小的比例保持宽高比
            
            // 计算视频在终端中的实际显示区域
            int video_display_width = video_width * scale_x;   // 640 * 0.055 = 35.2
            int video_display_height = video_height * scale_y; // 400 * 0.055 = 22
            
            // 居中显示
            int offset_x = (display_width - video_display_width) / 2 + 1; // (78-35)/2+1 = 22
            int offset_y = (display_height - video_display_height) / 2 + 1; // (22-22)/2+1 = 1
            
            // 修正：确保边界正确映射
            // 将视频坐标(0-639)映射到显示区域(offset_x 到 offset_x + video_display_width - 1)
            // 使用线性映射公式: y = offset_x + (x * (video_display_width - 1) / (video_width - 1))
            int box_left, box_right, box_top, box_bottom;
            
            if (video_display_width > 1) {
                box_left = offset_x + (pos.left * (video_display_width - 1)) / (video_width - 1);
                box_right = offset_x + (pos.right * (video_display_width - 1)) / (video_width - 1);
            } else {
                box_left = box_right = offset_x;
            }
            
            if (video_display_height > 1) {
                box_top = offset_y + (pos.top * (video_display_height - 1)) / (video_height - 1);
                box_bottom = offset_y + (pos.bottom * (video_display_height - 1)) / (video_height - 1);
            } else {
                box_top = box_bottom = offset_y;
            }
            
            // 确保在屏幕范围内
            if (box_left < 1) box_left = 1;
            if (box_right >= screen_width - 1) box_right = screen_width - 2;
            if (box_top < 1) box_top = 1;
            if (box_bottom >= screen_height - 1) box_bottom = screen_height - 2;
            
            // 确保左边界小于右边界，上边界小于下边界
            if (box_left > box_right) {
                int temp = box_left;
                box_left = box_right;
                box_right = temp;
            }
            if (box_top > box_bottom) {
                int temp = box_top;
                box_top = box_bottom;
                box_bottom = temp;
            }
            
            // 绘制视频区域边界
            for (int y = 0; y < screen_height; y++) {
                for (int x = 0; x < screen_width; x++) {
                    // 绘制外边框
                    if (y == 0 || y == screen_height - 1) {
                        printf("-");
                    } else if (x == 0 || x == screen_width - 1) {
                        printf("|");
                    } else {
                        // 检查是否在视频显示区域内
                        if (y >= offset_y && y < offset_y + video_display_height &&
                            x >= offset_x && x < offset_x + video_display_width) {
                            
                            // 检查是否在目标框边界上
                            if ((y == box_top || y == box_bottom) && 
                                x >= box_left && x <= box_right) {
                                printf("#"); // 目标框上下边界
                            } else if ((x == box_left || x == box_right) &&
                                      y >= box_top && y <= box_bottom) {
                                printf("#"); // 目标框左右边界
                            } 
                            // 检查是否在目标框内部
                            else if (y > box_top && y < box_bottom &&
                                    x > box_left && x < box_right) {
                                printf("."); // 目标框内部
                            } else {
                                printf(" "); // 视频区域但不在目标框内
                            }
                        } else {
                            printf(" "); // 不在视频显示区域内
                        }
                    }
                }
                printf("\n");
            }
            
            // 显示坐标信息
            printf("\n目标位置: L=%d, R=%d, T=%d, B=%d\n", 
                   pos.left, pos.right, pos.top, pos.bottom);
            printf("目标大小: %d x %d 像素 (视频范围: 640x400)\n", 
                   pos.right - pos.left, pos.bottom - pos.top);
            printf("终端位置: X=%d-%d, Y=%d-%d (显示区域: %dx%d)\n",
                   box_left, box_right, box_top, box_bottom,
                   video_display_width, video_display_height);
            printf("按任意键退出...\n");
            
            fflush(stdout);
        } else if (result < 0 && errno != EAGAIN) {
            perror("读取失败");
            break;
        } else {
            // 没有新数据，短暂休眠
            usleep(10000); // 10ms
        }
    }
    
    // 恢复终端设置
    tcsetattr(STDIN_FILENO, TCSANOW, &oldt);
    
    // 恢复阻塞模式
    fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
    
    printf("\n\n图形显示模式结束\n");
}

// 显示帮助信息
void display_help() {
    printf("\n=== 视频管理器帮助 ===\n");
    printf("本程序用于测试视频管理器驱动功能，主要功能包括：\n");
    printf("1. 设置颜色阈值 - 设置检测目标的RGB颜色阈值\n");
    printf("2. 获取当前阈值 - 查看当前设置的RGB颜色阈值\n");
    printf("3. 获取位置信息 - 获取最后一次检测到的目标位置\n");
    printf("4. 实时监控 - 实时显示目标位置变化（需要硬件产生中断）\n");
    printf("5. 测试帧率 (仅显示FPS)\n");
    printf("6. 实时图形显示 (方框显示)\n");
    printf("7. 退出程序 - 关闭设备并退出\n");
    printf("\n注意：实时监控功能需要硬件正常工作并产生中断信号。\n");
}

int main(int argc, char *argv[])
{
    int fd;
    int choice;
    char input[10];
    
    printf("视频管理器驱动测试程序 v2.0\n");
    printf("============================\n");
    
    // 注册信号处理函数
    signal(SIGINT, signal_handler);
    
    // 打开设备文件
    fd = open("/dev/video_manager", O_RDWR);
    if (fd < 0) {
        perror("打开设备文件失败");
        printf("请确保：\n");
        printf("1. 视频管理器驱动已加载 (insmod video_manager.ko)\n");
        printf("2. 设备节点已创建 (/dev/video_manager)\n");
        printf("3. 有正确的访问权限\n");
        return -1;
    }
    
    printf("设备打开成功！\n");
    
    // 主循环
    while (keep_running) {
        display_menu();
        
        if (fgets(input, sizeof(input), stdin) == NULL) {
            continue;
        }
        
        if (sscanf(input, "%d", &choice) != 1) {
            printf("错误: 请输入有效的选项\n");
            clear_input_buffer();
            continue;
        }
        
        clear_input_buffer();
        
        switch (choice) {
            case 1:
                set_threshold(fd);  // 需要提前定义
                break;
                
            case 2:
                get_threshold(fd);  // 需要提前定义
                break;
                
            case 3:
                get_position(fd);   // 需要提前定义
                break;
                
            case 4:
                monitor_position(fd);  // 需要提前定义
                break;
                
            case 5:
                test_fps_only(fd);
                break;
                
            case 6:
                realtime_graphical_display(fd);
                break;
                
            case 7:
                printf("正在退出程序...\n");
                keep_running = 0;
                break;
                
            default:
                printf("错误: 无效的选择，请输入1-7之间的数字\n");
                break;
        }
    }
    
    // 关闭设备
    close(fd);
    printf("设备已关闭，程序退出。\n");
    
    return 0;
}