# 重启后待办 / 故障交接单

时间点：2026-11-11 22:03（重启前）

## 背景一句话
目标是让 VMware NAT 网络里的 `petalinux` 开发 VM 固定使用 `192.168.189.130`。
固定绑定已写入配置，但 **VMnetDHCP 服务在重启后失去服务能力**（guest 拿不到 IP，主机 DISCOVER 探测无应答），
多次重启服务 / 还原配置 / 重置适配器 / `vnetlib` 官方通道均无效 → 决定重启整机重建网络栈。

## 已落地的改动（重启后仍然有效）
1. `C:\ProgramData\VMware\vmnetdhcp.conf` 末尾新增固定绑定：
   ```
   host petalinux {
       hardware ethernet 00:0c:29:51:6e:83;
       fixed-address 192.168.189.130;
   }
   ```
2. `C:\ProgramData\VMware\vmnetdhcp.leases` 已清空历史记录（只保留 6 行注释头），
   其中原本有一条 `192.168.189.130 ... abandoned;` 的毒化记录。
3. 适配器 IP 已确认（重启前最后一次核对）：VMnet1 = 192.168.187.1，VMnet8 = 192.168.189.1。

## 备份位置
- `C:\ProgramData\VMware\vmnetdhcp.conf.bak-20261111-212510`
- `C:\ProgramData\VMware\vmnetdhcp.leases.bak-20261111-212510`
- 工作区副本：`.vm-ip-pin\vmnetdhcp.conf.orig`、`.vm-ip-pin\vmnetdhcp.leases.orig`

## 重启后验证清单
1. `Get-Service VMnetDHCP` → Running
2. 适配器 IP 回到 192.168.187.1 / 192.168.189.1（`ipconfig`）
3. 启动 VM，等 30 秒，检查：
   - `C:\ProgramData\VMware\vmnetdhcp.leases` 出现 `lease 192.168.189.130` + `client-hostname "petalinux"`
   - `ping 192.168.189.130` 通
4. 若 DHCP 仍不工作 → 走备选：VMware「虚拟网络编辑器」→ 还原默认设置（会覆盖 vmnetdhcp.conf，需要重新加回上面的 host 块），
   或在 guest 内配静态 IP 192.168.189.130/24，网关 192.168.189.2。

## 回滚
把 `vmnetdhcp.conf.bak-20261111-212510` 覆盖回 `vmnetdhcp.conf` 即可去掉固定绑定（不需要改 leases）。

## 相关脚本（工作区 .vm-ip-pin\）
- `vm-pin-ip.ps1` 加绑定 + 重建租约库
- `vm-diag.ps1` A/B/C 三组对照
- `vm-apply-probe.ps1` 应用配置 + DHCPDISCOVER 探测
- `vm-net-reset.ps1` 重置服务与适配器
- `vm-fix-ip.ps1` 恢复适配器静态 IP
- `vm-vnetlib.ps1` 走 vnetlib 官方通道
- 日志：`run.log` `diag.log` `apply.log` `reset.log` `fixip.log` `vnetlib.log`
