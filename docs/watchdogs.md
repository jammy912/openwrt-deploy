# Watchdog / 自癒腳本群

> 這套系統靠多個 watchdog 各守一塊,故障自動修。這份彙整每個守什麼、怎麼修、cron 頻率。

---

## 總表

| 腳本 | 守什麼 | 偵測 | 修復 |
|------|--------|------|------|
| **watchdog.sh** | 對外連線 | ping 三個 DNS(8.8.8.8 等)全不通 | **重開機**(最後手段) |
| **check-pbr-wg.sh** | wg 介面 + DBR | ping wg / handshake 年齡 / DBR set | 切回 wan(抖動確認)、重建 DBR rule、failover |
| **ts-watchdog.sh** | tailscale exit node + 節點互通 | table 52 路由 / peer ICMP / 出口 IP | 補介面 IP → 重設 exit node → 重啟 tailscaled |
| **check-wg-peers.sh** | wg peer 連入/斷線 | handshake 變化 | 只推播通知(不修) |
| **wifi-monitor.sh** | wifi 存活 | (實例守護) | 觸發 wifi-signal |

---

## watchdog.sh（最後手段：重開機）

- ping 三個關鍵 DNS,**全部不通才重開機**(避免單點誤判)。
- 這是「救不回就重來」的兜底。cron 定時跑。
- ⚠️ 會真的 reboot,誤觸代價大,所以要三個 DNS 全掛才動。

## check-pbr-wg.sh（wg + DBR 健檢，最複雜）

四個階段(詳見 [DBR-PBR-routing.md] §健檢):
1. **wg 介面 ping 健檢**:連敗 `DOWN_CONFIRM=2` 輪才切回 wan(抗抖動),連勝 `UP_CONFIRM=4`
   輪才切回 wg(冷靜期)。1 小時 DOWN 超 10 次→短鎖 5 分;24h 累 3 次→長鎖 24h。
2. **uci enabled 同步**。
3. **DBR 健檢**(第三階段):handshake 年齡>180s 或介面不存在→判 down,移除 fwmark。
   **不帶 `-q` 手動跑會列每介面摘要**(handshake/ping/判定/rule)。
4. **server wg 多 peer 的 0.0.0.0/0 出口 failover**。
- **NO_FALLBACK**(`-n wg4,wg5`):這些介面 DOWN 時不切 wan,保持 black-hole(避免洩真實 IP)。
- 全程不呼叫 pbr reload(避免中斷其他介面)。

## ts-watchdog.sh（tailscale 自癒）

三層健檢,**放在 exit-node gate 之前的健檢 0/0.5 讓純互通機也能用**:
- **健檢 0**:table 52 無 100.64 路由(節點互通斷,但 `tailscale ping` 經 DERP 仍通易誤判)
  → 重啟 tailscaled 重裝路由。
- **健檢 0.5**:table 52 在、tailscale ping 通,但 peer 普通 ICMP 全掉(NAT 打洞退化/endpoint
  學歪)→ 連 `PEER_FAIL_CONFIRM=2` 輪失敗才重啟(防抖動)。
- **健檢 1-3**:exit node 設定/出口(ExitNodeID 空→純互通機,乾淨跳過)。
- Gate:服務 disable / WantRunning=false / 介面不存在 → 安靜退出(尊重使用者停用)。
- cron 每 10 分。詳見部署過的機器(如 .6 獨立體系是手動傳的)。

## check-wg-peers.sh（連入通知）

wg peer handshake 變化時推播(誰連進來/斷線)。**只通知不修**。用法:
`check-wg-peers.sh <iface> [timeout]`。

## 相關

- DBR 健檢細節 → [DBR-PBR-routing.md]
- tailscale 排程開關(ts-schedule-on/off)→ [tailscale.md]
- 頂層 → [ARCHITECTURE.md] §5
