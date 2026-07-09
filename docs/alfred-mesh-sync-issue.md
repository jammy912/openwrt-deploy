# ⚠️ 未解問題：alfred mesh 資料跨機不互通（auto-role 仲裁失效）

> 2026-07-08 深度診斷,**真兇縮小但未解**。記錄已排除的死路 + 待試方向,避免下次從頭來過。
> 症狀:多台都當主 gateway 搶同一個 .1(IP 衝突),「切換要很久才發現對方」。

---

## 症狀

- 兩台(.8 RAX3000Z / .9 MX4200)開機後**都判自己是主 gateway**,都搶 `192.168.1.1` → IP 衝突
  → ssh/tailscale 都 timeout(衝突害的)。
- 「切換要很久才發現對方」——最終會勉強收斂(靠 fallback),但很慢,且 priority 接近時會雙主。

## 根因鏈（已用 tcpdump 抓包證實）

auto-role 的主 gateway 仲裁**靠 alfred 廣播/讀取彼此的 priority**(type 64):
```
每台 alfred -s 64 寫自己的 {priority, wan_status, ...}
每台 alfred -r 64 讀所有節點 → 找 priority 比自己高的 → 讓位
```

**問題:alfred 的資料跨機完全不互通**,每台 `alfred -r` 只讀到自己 → 都以為自己 priority 最高
→ 都當主。

逐層確認(抓包):
| 層 | 狀態 |
|----|------|
| batman-adv 底層 | ✅ **完美**(雙向 originator 255 滿分、鄰居互見) |
| alfred 封包傳輸 | ✅ **正常**——alfred 用 **UDP port 16720 廣播**(不是舊版 ethertype 0x4242)。抓包證實 .9 的廣播(192.168.1.5:16720)**確實出現在 .8 的 br-lan 上** |
| **alfred 應用層彙整** | ❌ **這裡壞**——封包收到了,但 `alfred -r` 讀不到對方資料。收到卻不彙整 |

**真兇範圍**:alfred 應用層在這個 **batman 2025.4 + bat0-掛在-br-lan-底下** 的架構下,
收到跨機廣播卻不彙整。config/網路層都正常,是 alfred/batman 版本或 bridge 互動的深層問題。

## ❌ 已排除的死路（別再試）

1. **alfred config `interface`**:`br-lan` 是 rc.local 補的**正確預設**,不是被改壞。
   改 `bat0` 能讓 alfred 起來(如果 br-lan 被占),但不解決互通。
2. **multicast_mode**:`batctl mm disable` + 重啟 alfred,等 35 秒,**零改善**。不是 mm。
3. **master/master → master/slave**:改成「主 gw=master、副=slave」(auto-role 依角色設
   `alfred.alfred.mode`),config **有正確切換**(實測 .9 master→slave),但 **slave 的資料
   一樣傳不到 master**,等 35 秒 master 仍只讀到自己。**改法無效,已還原。**
   → 教訓:master/slave 不是解法;slave 狀態反而更糟(資料完全孤立)。
4. **殺程序/清 sock**:`Address in use` 是因為 alfred **本來就在跑**(init 起的),
   `pgrep -x alfred` 抓不到完整路徑的程序 → 誤判沒跑 → 手動再起撞 bind。
   **用 `ps w | grep '[/]usr/sbin/alfred'` 才抓得到,別用 `pgrep -x alfred`。**

## 診斷指令速查（下次接手用）

```sh
# alfred 真實程序(別用 pgrep -x)
ps w | grep '[/]usr/sbin/alfred'

# 各節點讀到的 priority(只有自己=不互通)
alfred -r 64 2>/dev/null | grep -oE '"priority\\":[0-9]+' | grep -oE '[0-9]+' | sort -rn

# batman 底層通不通(originator 255=完美)
batctl o ; batctl n

# 抓 alfred 封包有沒有跨機(UDP 16720,不是 0x4242!)
# 注意:這批機器沒有 timeout 指令,tcpdump 用 -c N 或背景 PID kill
tcpdump -i br-lan -e -n -c 20 udp port 16720   # 有對方 IP=封包有到,問題在 alfred 應用層

# multicast flags(Bridged + No IGMP Querier)
batctl mcast_flags
```

## 現況（暫時可用，靠 fallback）

auto-role 的 alfred 仲裁失效,但退化到 fallback 勉強收斂:
- **`batctl gwl`**(batman gateway list,gw_bandwidth=priority)——alfred 空時的 fallback。
- **`BOOT_DELAY`**(開機延遲,`60 + (100-pri)*3` 秒)——priority 低的等越久,讓高 pri 先搶主。

所以多數情況慢慢會好,只有 priority 接近或開機時序巧合才暴露成雙主搶 IP。

**防雙主搶 IP 的最後防線 = ARP DAD V2**(`4b78023`,見 [auto-role.md]):即使 alfred
仲裁失效,DAD 用「priority 退避 + 持續偵測 .1 第二個 MAC + MAC tie-break」確保最終
只一台佔 .1。所以 alfred 沒修好也不會持續雙主(DAD 會收斂),只是切換仍靠慢速 fallback。

## 🔜 待試方向（未做，需規劃）

| 方案 | 做法 | 評估 |
|------|------|------|
| **A. auto-role 改用 batctl gwl 為主仲裁**(推薦) | 不依賴壞掉的 alfred。batman gwl 底層確定能跨機(batman 雙向已驗證)。把 gwl 從 fallback 升為主力 | 最務實,底層確定通 |
| **B. 加大 BOOT_DELAY 差距 + 靠 gwl** | priority 差距對應更大開機延遲,純靠時序 | 簡單但不夠即時 |
| **C. 深查 alfred/batman 版本 bug** | 查已知 bug、換版本 | 工程大、不確定 |

> ⚠️ 動這個要小心:改仲裁邏輯 = 改「誰當主 gw」,弄錯會雙主搶 IP 或全部不當主(沒人上網)。
> 先 `--dry-run` 測、且要能從第二條路(tailscale)進機補救。

## 相關

- auto-role 角色判斷 → [auto-role.md]
- 頂層 → [ARCHITECTURE.md] §2
