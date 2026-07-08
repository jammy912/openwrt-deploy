# 上游設備 / 推播佇列 / 雜項工具

> 收尾的子系統:上游 cable modem(Hitron)、推播離線佇列、其他維運工具。
> 部署鏈已獨立成 [deployment.md]。

---

## 一、上游設備（Hitron cable modem）

家用網路上層是 Hitron CGN5-AP（`192.168.168.1`）。

| 腳本 | 用途 |
|------|------|
| `hitron-pf.sh` | 把 Hitron 的 wg* port forward 規則 localIpAddr **改指向本機 WAN IP**。auto-role 切主 gw 時呼叫——因為主 gw 換機器,WG 入站要跟著改指向。 |
| `hitron_reboot.sh` | 透過 Hitron Web API 重開上層分享器 |

- Hitron PF 設定會被 `sync-uploadconfig` 備份到 Sheet(`.hitron-pf.json`)。
- 缺 `.hitron-pf.json` 時 sync 會強制下載補回。

## 二、推播離線佇列（push-queue）

```
斷網/reboot 時 → queue_push 寫 JSON 進 .pushqueue/
   ▼
開機穩定後 → push-queue.sh 逐一送出後刪除
```
- 確保「斷網期間的告警」開機後補送,不丟失。
- `push-status.sh`:推播系統狀態(CPU 溫度/AGH 記憶體/可用記憶體/Tx-Power),cron 定時。
- `push-businfo.sh`:公車到站推播(TDX API,個人用)。

## 三、雜項維運工具

| 腳本 | 用途 |
|------|------|
| `blockdev.sh <name> add/del/status` | 依 DHCP static host 名字封鎖/解封裝置上網(家長控制) |
| `wg-dns-hosts.sh` | 用 upstream DNS 解析 wg peer 的 endpoint_host 寫入 /etc/hosts(避免啟動 DNS 雞生蛋) |
| `blockdev.sh` / `kick-wifi-client.sh` | 封鎖 / 踢 client |
| `lock-handler.sh` | 提供 cron 全域排隊鎖、PID 鎖(多腳本共用) |
| `usb-umount.sh` / `sync-agh-usb.sh` / `agh-usb-init.inc` | USB 掛載 / AGH work-dir 放 USB↔RAM(有 USB 機型) |

## 四、AGH / DNS 鏈（簡述）

- gateway 機裝 AdGuardHome,client :53 被 firewall redirect(`adgh_*`)hijack 到 AGH:53535。
- `check-adguard.sh`:AGH 健康時 upstream 指向 AGH(SELF)、開 hijack;不健康時退回 dnsmasq
  直連上游 DNS,關 hijack。動態選最佳 upstream(SELF/PEER/DNS)。
- AGH 客製化(upstream DoT/DoH、AAAA 擋、快取)在 deploy.sh 安裝時套用。
- DNS 繞過防護 → [private-dns-doh.md]。

## 相關

- 頂層 → [ARCHITECTURE.md]
- RAM overlay 落地 → [ram-overlay-sync-flash.md]
