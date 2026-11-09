/******************************************************************************
 * axi_a1_test.c  --  A 线第一阶段裸机自检（Vitis 2020.2 / Zynq-7020）
 *
 * 用法：
 *   1) 用 A.3 导出的新 XSA 建 Vitis Platform（standalone），再建 Application
 *   2) 把本文件加进 src/，把 BASEADDR 改成 Address Editor 里的实际基址
 *   3) Run/Debug on hardware（先用 XSCT 完成 ps7_init + ps7_post_config + fpga 下载）
 *
 * 检查项（串口 115200 打印，PASS/FAIL 逐条给出）：
 *   [1] ID 寄存器 = 0x56495331
 *   [2] SCRATCH 读写（含字节使能）
 *   [3] IRQ_EN 读写
 *   [4] SW_IRQ 人为触发 -> 中断进入 -> W1C 清零
 *   [5] 帧末中断：60 s 内 ISR 计数与 FRAME_CNT 一致（差值 <= 1）
 *   [6] 结果寄存器可读（CX/CY/FLAGS），并打印
 ******************************************************************************/

#include <stdio.h>
#include "xil_printf.h"
#include "xil_io.h"
#include "xparameters.h"
#include "xscugic.h"
#include "xil_exception.h"

/* ---- 按 Address Editor 的实际值改这里 ---------------------------------- */
#define BASEADDR        0x43C00000u
#define FPGA_INT_ID     XPS_FPGA0_INT_ID      /* IRQ_F2P[0] -> 61 */

/* ---- 寄存器偏移（与 rtl/vision_regs_axi.v 一致） ------------------------ */
#define R_ID            0x00
#define R_CTRL          0x04
#define R_IRQ_EN        0x08
#define R_IRQ_STATUS    0x0C
#define R_SCRATCH       0x10
#define R_FRAME_CNT     0x14
#define R_FPS           0x18
#define R_FLAGS         0x1C
#define R_CX            0x20
#define R_CY            0x24
#define R_AX            0x28
#define R_AY            0x2C

#define REG(off)        (BASEADDR + (off))
#define RD(off)         Xil_In32(REG(off))
#define WR(off, v)      Xil_Out32(REG(off), (v))

#define ID_VALUE        0x56495331u

static XScuGic gic;
static volatile u32 irq_cnt = 0;
static volatile u32 irq_last_cx = 0;

static int pass = 0, fail = 0;

static void check(const char *name, int ok, u32 got, u32 exp)
{
    if (ok) {
        pass++;
        xil_printf("  PASS  %-22s = 0x%08X\r\n", name, got);
    } else {
        fail++;
        xil_printf("  FAIL  %-22s got=0x%08X exp=0x%08X\r\n", name, got, exp);
    }
}

/* ---- ISR：读一下结果 + W1C 清中断（电平中断必须清，否则只进一次） ---- */
static void irq_handler(void *arg)
{
    (void)arg;
    irq_cnt++;
    irq_last_cx = RD(R_CX);
    WR(R_IRQ_STATUS, 1);            /* W1C */
}

static int setup_gic(void)
{
    XScuGic_Config *cfg;
    int status;

    cfg = XScuGic_LookupConfig(XPAR_SCUGIC_SINGLE_DEVICE_ID);
    if (!cfg) return XST_FAILURE;

    status = XScuGic_CfgInitialize(&gic, cfg, cfg->CpuBaseAddress);
    if (status != XST_SUCCESS) return status;

    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT,
                                 (Xil_ExceptionHandler)XScuGic_InterruptHandler,
                                 &gic);
    Xil_ExceptionEnable();

    status = XScuGic_Connect(&gic, FPGA_INT_ID,
                             (Xil_ExceptionHandler)irq_handler, (void *)0);
    if (status != XST_SUCCESS) return status;

    XScuGic_Enable(&gic, FPGA_INT_ID);
    return XST_SUCCESS;
}

int main(void)
{
    u32 v, id, cnt0, cnt1;
    int i;

    xil_printf("\r\n==== A1 AXI4-Lite register test ====\r\n");
    xil_printf("base = 0x%08X\r\n", BASEADDR);

    /* [1] ID ------------------------------------------------------------- */
    id = RD(R_ID);
    check("ID", id == ID_VALUE, id, ID_VALUE);
    if (id != ID_VALUE) {
        xil_printf("ID wrong -> check base address / GP0 / BD regenerate\r\n");
        goto summary;
    }

    /* [2] SCRATCH -------------------------------------------------------- */
    WR(R_SCRATCH, 0xDEADBEEFu);
    v = RD(R_SCRATCH);
    check("SCRATCH rw", v == 0xDEADBEEFu, v, 0xDEADBEEFu);

    WR(R_SCRATCH, 0x11223344u);
    WR(R_SCRATCH, 0x00AA0000u);      /* only byte 2 (driver writes are 32-bit) */
    v = RD(R_SCRATCH);
    check("SCRATCH strobe", v == 0x11AA3344u, v, 0x11AA3344u);

    /* [3] IRQ_EN --------------------------------------------------------- */
    WR(R_IRQ_EN, 1);
    v = RD(R_IRQ_EN);
    check("IRQ_EN", v == 1u, v, 1u);

    /* [4] SW_IRQ -> GIC -> W1C ------------------------------------------ */
    if (setup_gic() != XST_SUCCESS) {
        xil_printf("  FAIL  GIC init\r\n");
        fail++;
        goto summary;
    }

    irq_cnt = 0;
    WR(R_CTRL, 1);                    /* CTRL.SW_IRQ */
    for (i = 0; i < 100000 && irq_cnt == 0; i++) { ; }
    check("SW_IRQ entered", irq_cnt >= 1, irq_cnt, 1);
    v = RD(R_IRQ_STATUS);
    check("SW_IRQ W1C", v == 0, v, 0);

    /* [5] frame IRQ vs FRAME_CNT ---------------------------------------- */
    WR(R_CTRL, 2);                    /* CLR_CNT */
    irq_cnt = 0;
    cnt0 = RD(R_FRAME_CNT);

    /* 等 3 秒（按 30 fps 大约 90 帧；用简单循环计时，不依赖定时器） */
    for (i = 0; i < 60000000; i++) { __asm__ __volatile__("nop"); }
    cnt1 = RD(R_FRAME_CNT);

    xil_printf("  frame_cnt=%u  irq_cnt=%u  fps=%u  cx=%u  flags=0x%X\r\n",
               (unsigned)cnt1, (unsigned)irq_cnt,
               (unsigned)RD(R_FPS), (unsigned)RD(R_CX),
               (unsigned)RD(R_FLAGS));
    check("frame tick seen", cnt1 > cnt0, cnt1, cnt0 + 1);
    check("irq ~= frame_cnt", (cnt1 > irq_cnt ? cnt1 - irq_cnt : irq_cnt - cnt1) <= 1,
          irq_cnt, cnt1);

    /* [6] result registers ---------------------------------------------- */
    xil_printf("  CX=%u CY=%u AX=%u AY=%u FLAGS=0x%08X\r\n",
               (unsigned)RD(R_CX), (unsigned)RD(R_CY),
               (unsigned)RD(R_AX), (unsigned)RD(R_AY),
               (unsigned)RD(R_FLAGS));

summary:
    xil_printf("--------------------------------------\r\n");
    if (fail == 0) xil_printf("ALL CHECKS PASSED (%d)\r\n", pass);
    else           xil_printf("FAILED: %d of %d\r\n", fail, pass + fail);

    while (1) { }
    return 0;
}
