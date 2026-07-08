# 私人 DNS / DoH / DoT：為什麼擋不乾淨，該怎麼處理

> 2026-07-07 定調。同戶方案的前提是「client DNS 由你控制」,但加密 DNS(DoT/DoH)
> 故意繞過本地 DNS → 繞過你的 hijack/DBR。這份記清楚:誰會繞過、能不能擋、怎麼處理。

---

## 私人 DNS 是什麼、為什麼跟同戶衝突

私人 DNS = 讓裝置的 DNS 查詢走**加密通道**(DoT/DoH),不走明文,好處是隱私、防 ISP
劫持。但它**故意繞過本地網路的 DNS** → 繞過你的 `:53` hijack + DBR → 功能流量不進 DBR
→ 同戶失效 / 圖出不來。

**本質是價值觀衝突**:私人 DNS 要「不讓網路管我的 DNS」,你的方案要「管住 client DNS 才能
做同戶」。**在自己家、要走自家 VPN 做同戶的裝置上,關掉私人 DNS 對你有利**(隱私價值只對
「在外用公共 WiFi」有意義)。

## 兩種加密 DNS，擋法不同

| 類型 | 走哪 | 能不能從路由器擋 |
|------|------|:---------------:|
| **DoT** | TCP **853** | 能擋,但**擋 853 會害 Netflix App**(見下),別擋 |
| **DoH** | **443**(混在 HTTPS) | ⚠️ 難擋,只能擋已知 DoH IP/域名 |

## ⚠️ Android vs iOS 差很大

| | Android | iOS/iPadOS/tvOS |
|---|---------|-----------------|
| 系統級私人 DNS 開關 | ✅ 有(設定→網路→私人 DNS),**容易誤開** | ❌ **沒有**,預設用網路給的明文 DNS |
| 預設行為 | 「自動」(會試 DoT) | **走你的路由器 DNS**(受你控制) |
| 對同戶威脅 | **高**(誤開就繞過) | **低**(要主動裝 DNS 描述檔/App 才繞過) |

**結論**:主要盯 **Android** 裝置的私人 DNS(小新 Pad 等)。iOS/AppleTV 天生對同戶友善,
除非裝了 Cloudflare/AdGuard App 或開了 **iCloud Private Relay**(iOS 15+,設定→Apple ID→
iCloud→Private Relay 關掉)。

## Android 私人 DNS 三個選項

| 設定 | 行為 | 對同戶 |
|------|------|--------|
| **關閉** | 用網路給的 DNS(你的路由器) | ✅ 走 hijack/DBR,正常 |
| **自動** | 先試 DoT,失敗回落明文 :53 | ⚠️ DoT 通就繞過;失敗才回落 |
| **私人 DNS 主機名**(填 dns.google 等) | 強制 DoH/DoT,**不回落** | ❌ 完全繞過(今天平板的狀況) |

## ❌ 為什麼不能用「擋 853」或「DNAT 853→AGH」

- **擋 853(Block-DoT REJECT)**:實測**害 Netflix App**(AppleTV/手機圖不出、影片轉圈)。
  Netflix 裝置需要 DoT 正常。**別擋 853。**(見 MAINTAINER-GUIDE §4)
- **DNAT 853→AGH**:DoT 是 **TLS 加密、會驗憑證**。轉到你的 AGH,AGH 出示的憑證不是
  `dns.google` → client TLS 握手失敗 → 跟 REJECT 一樣失敗,還更慢/可能卡住。
  **DoT 的 TLS 憑證驗證就是設計來擋這種劫持的,做不到透明劫持。**
- 對比:明文 `:53` 能 hijack DNAT 到 AGH,是因為它沒加密沒憑證。DoT/DoH 加了 TLS 就失效。

## ✅ 能做的（由乾淨到激進）

### 層 1（最推薦）：AGH 擋「已知 DoH/DoT 服務域名」
client 連 DoH 前要先**解析**它的域名 → AGH 回 NXDOMAIN → DoH 失敗回落。
AGH → 過濾器 → 自訂規則,加:
```
||dns.google^
||cloudflare-dns.com^
||one.one.one.one^
||dns.quad9.net^
||mozilla.cloudflare-dns.com^
||chrome.cloudflare-dns.com^
```
或訂閱現成清單(hagezi DoH/VPN/Proxy Bypass)。**副作用極小,擋掉大多數用域名找 DoH 的裝置。
擋不了「手動填 IP 的 DoH」。**

### 層 2：擋 v6 DNS 到路由器(已部署)
`Block-LAN-IPv6-ToRouter`(input lan→此裝置 v6 **dest_port=53** REJECT)逼 v6 DNS 走 v4。
**不擋 v6 上網、不擋 DHCPv6。** ⚠️ 必須限 :53,否則擋 DHCPv6(547) 害 Android 拿不到 IP。
見 MAINTAINER-GUIDE §4 與 firewall-direction-basics.md。

### 層 3：擋已知公共 DNS 的 IP(443+853)
針對「手動填 IP 的 DoH」——擋 client→wan 連 1.1.1.1/8.8.8.8/9.9.9.9 的 443+853。
**只擋特定 IP(不是全 443),不會像 Block-DoT 害 Netflix**,但要維護清單,且擋掉這些 IP
的所有服務。

### 層 4（最徹底）：裝置上關私人 DNS
家裡自己的裝置(要做同戶的)→ **直接在裝置上把私人 DNS 設「關閉」**。這是唯一 100% 的
方法。比在路由器端追著擋簡單可靠。

## 建議

- **家裡自己的裝置**(要同戶的平板/手機/AppleTV)→ **層 4**(裝置關私人 DNS)最乾淨。
  它們在你家、信任你的網路、要走你的 DBR,開私人 DNS 只害自己看不了 Netflix。
- **訪客/不受控裝置** → 層 1(AGH 擋 DoH 域名)為主,層 3 補強。
- **絕不回去用擋 853**(害 App)。

## 診斷：client 是不是在用 DoH

conntrack 若看到「client 連一堆 Google IP(142.250/216.239/108.177)但 `dport=53` 查詢=0」
→ 它在用 **v4 DoH**(那些是 `dns.google`),不是問你的 DNS。這就是今天抓平板的判斷法。
