# Tailscale / Headscale

> mesh 節點互通 + exit node。自架 headscale 當控制器(不靠 tailscale 官方)。
> exit node 自癒見 [watchdogs.md];備援 VPN(ZeroTier)另見 [zerotier-backup-vpn.md]。

---

## 架構

- **控制器**:自架 **headscale**(login-server = 你的 headscale 域名,見 memory)。
  等同 tailscale 官方後台,但完全自主。
- **節點互通**:各機器 tailscale IP `100.64.0.x`,peer 之間直連或經 DERP。
- **exit node**:部分機器 offer exit node,讓走它出口的裝置偽裝成從該處出網。
- **安裝方式**:有的機器手動裝 binary(如 .6 手動 1.98.8)、有的 apk/opkg 套件。
  ⚠️ 手動 binary 覆蓋套件版時,`tailscale version` 顯示手動版,但 opkg/apk 登記套件版。

## 定時開關（ts-schedule-on / off）

| 腳本 | 做什麼 |
|------|--------|
| `ts-schedule-off.sh` | `tailscale down`(整個斷線,走 WAN)。**ts-watchdog 的 disable gate(WantRunning=false)會擋住,不會救回來** |
| `ts-schedule-on.sh [exit-node]` | `tailscale up` + 設回 exit node |

由 cron 排程呼叫(如夜間關、白天開)。

## 服務守護（三層，見 watchdogs.md）

| 層 | 抓什麼 |
|----|--------|
| procd respawn | tailscaled 程序掛掉→秒級重拉 |
| ts-watchdog 健檢 0/0.5 | 程序活著但節點互通斷/資料面僵死→重啟 |
| ts-watchdog 健檢 1-3 | exit node 邏輯壞→補設/重啟(不走 exit node 的機器乾淨跳過) |

## OpenWrt tailscale 套件的坑

- 資料目錄 `/tmp/lib/tailscale`(部分)或 `/var/lib/tailscale`——`--state` 路徑要對,
  否則重登入(sysupgrade.conf 保留 `/etc/tailscale/` 免重登)。
- wan zone 要放行 udp/41641 入站(打洞首包),否則只能主動打洞、被動失敗退 DERP。

## ⚠️ 需先問過使用者的操作（高風險）

- `tailscale up --reset`、換 login-server、動 tailscale 本體設定
- 這些可能斷線或需重登,動前確認有第二條進入路徑

## 相關

- exit node 自癒 → [watchdogs.md]
- 具體 login-server/IP → memory
- 頂層 → [ARCHITECTURE.md] §5
