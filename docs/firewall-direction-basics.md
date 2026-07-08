# 防火牆三個方向：傳入 / 傳出 / 區域內轉送（Input / Output / Forward）

> OpenWrt（fw4/nftables）防火牆最容易混淆的核心概念。設任何規則前先搞懂封包走哪個 chain，
> 否則會像 2026-07-07 那次——想擋 v6 DNS 卻擋成 v6 上網，害 Netflix App 全掛。
> 實例對照見 [`MAINTAINER-GUIDE-netflix-dbr.md`](MAINTAINER-GUIDE-netflix-dbr.md) §4。

---

## 一句話核心：封包「去哪裡」決定走哪條 chain

路由器收到封包，第一件事是判斷**目的地是「路由器自己」還是「要穿過去別的地方」**：

```
封包目的地 = 路由器自己的 IP        → 走 INPUT chain   (傳入)
封包目的地 = 別的地方(要穿過去)      → 走 FORWARD chain (區域內轉送)
路由器自己發起的封包                 → 走 OUTPUT chain  (傳出)
```

**最常見的誤解**：「上網不也經過路由器嗎？為什麼擋 input 不影響上網？」
→ **「經過路由器」和「目的地是路由器」是兩回事。** 上網是**借道穿過**（forward），
問路由器的 DNS 才是**目的地是它**（input）。擋 input 完全不影響 forward。

---

## 三個方向逐一解釋

以「你的手機（在 lan zone）」為例：

### 1. 傳入 Input = 「別人 → 路由器自己」

封包**目的地是路由器本身**的服務（路由器是終點）。

| 例子 | 目的地 |
|------|--------|
| 手機問路由器的 DNS（:53） | 路由器 |
| 手機開 LuCI 管理網頁（:80/:443） | 路由器 |
| 手機 ssh 進路由器（:22） | 路由器 |
| 手機 ping 路由器 | 路由器 |

`input=ACCEPT` = 允許該 zone 的裝置存取「路由器自己的服務」。

### 2. 傳出 Output = 「路由器自己 → 別人」

**路由器主動發起**的封包（路由器是來源）。

| 例子 | 說明 |
|------|------|
| 路由器去問上游 DNS（AGH 的 DoT/DoH → quad9/cloudflare） | 路由器主動連外 |
| 路由器跑 `curl` / `ping` / sync-googleconfig 下載 | 路由器自己發起 |
| tailscale / wireguard 主動連對端 | 路由器發起 |

★ **重要推論**：擋 client 的流量（input/forward）**碰不到 output**。所以
「擋 client DoT」不會影響「路由器 AGH 自己的上游 DoT」——後者走 output。

### 3. 區域內轉送 Forward = 「穿過路由器，A zone → B zone」

封包**從一個 zone 穿到另一個 zone**，路由器只是中轉站（不是終點也不是來源）。

| 例子 | 從 → 到 |
|------|---------|
| 手機上網 | lan → wan |
| 手機連 VPN 出去 | lan → vpn |
| 手機看 Netflix / 任何網站 | lan → wan（或 vpn） |
| 手機存取家裡 NAS | lan → lan（同 zone 內轉送） |

**上網、看影片、走 VPN 全都是 forward。** 這是「路由/轉發」，路由器只是借道穿過。

OpenWrt 的 forward 有兩層設定：
- **zone 的 `forward`**：該 zone **內部**裝置互相轉送（如 lan↔lan）。
- **`config forwarding`（src→dest）**：**跨 zone** 轉送（如 lan→wan 才能上網）。

---

## 一張圖總結

```
                    ┌─────────────────────┐
   手機問DNS ──────▶│                     │
   (INPUT,到路由器)  │                     │
                    │      路由器          │──────▶ 路由器連上游DNS/curl
                    │                     │        (OUTPUT,路由器發起)
   手機上網 ────────┼─────────────────────┼──────▶ google.com / netflix
   (FORWARD,穿過去)  │   lan zone → wan    │
                    └─────────────────────┘
```

---

## 對照 LuCI「防火牆 → 區域」畫面的欄位

LuCI 的 網路 → 防火牆 → 區域,每個 zone 一列,欄位就是這三方向:

```
區域   區域⇒轉送          傳入   傳出   區域內轉送   NAT
lan  ⇒ wan/wg_disable/ts  接受   接受    接受        ✓
       (REJECT all others)
```

| LuCI 欄位 | = 三方向 | 意思 | 動它會影響 |
|-----------|---------|------|-----------|
| **傳入** | INPUT | lan 裝置**連路由器自己**(問 DNS :53、開 LuCI、ssh) | 只影響「存取路由器服務」,**不影響上網** |
| **傳出** | OUTPUT | 路由器**回應/主動發**給 lan | 路由器自己的流量 |
| **區域內轉送** | FORWARD(同 zone) | lan 裝置**互連**(手機↔NAS) | 內網互通 |
| **區域⇒轉送: wan** | FORWARD(跨 zone) | lan **穿過路由器上網** | **這才是上網那條路** |
| **NAT** | — | lan→wan 出去做位址轉換 | v4 上網靠它 |

**關鍵**:「傳入」和「區域⇒轉送」是**兩個獨立欄位**。這就是「擋 input 不影響上網」的
UI 層證據——上網是「區域⇒轉送: wan」,連路由器是「傳入」,動一個不碰另一個。

---

## 實例：為什麼「擋 v6 DNS」要用 input 而不是 forward

2026-07-07 的教訓——目標是「逼 client 的 DNS 走 v4」（讓 Netflix 功能流量進 v4 DBR），
但**不能斷 client 的 v6 上網**（否則 Netflix App 需要的 v6 掛掉）。

| 規則 | chain / LuCI 欄位 | 擋到 | 沒擋到 | 結果 |
|------|------------------|------|--------|------|
| **Block-LAN-IPv6-ToRouter**<br>`input, src=lan, family=ipv6, dest_port=53, REJECT` | **INPUT**<br>=「傳入」欄 | client 用 v6 問**路由器**的 **:53 DNS** | client v6 上網(forward)<br>DHCPv6(547)<br>路由器自己的 v6(output) | ✅ 正解：只擋 v6 DNS，逼走 v4，App 不壞 |
| ~~Block-IPv6-WAN~~（已移除）<br>`forward, dest=wan, family=ipv6` | **FORWARD**<br>=「區域⇒轉送 wan」 | client v6 **上網** | — | ❌ 擋掉上網 → Netflix App 圖不出、影片不播 |
| ~~Block-DoT~~（已移除）<br>`forward, dport=853` | **FORWARD**<br>=「區域⇒轉送 wan」 | client DoT 上網 | — | ❌ Netflix 裝置需要 DoT，擋掉就壞 |

**關鍵**：`Block-IPv6-WAN` 動的是 LuCI 的「**區域⇒轉送 wan**」（=上網）→ 害 App；
`ToRouter` 動的是「**傳入**」（=連路由器自己）→ 只斷 v6 DNS，上網照常。
**同樣擋 v6，差別只在動哪一欄——一字之差（input vs forward），一個能用一個害死。**

> ⚠️ **ToRouter 還踩過第二個坑（2026-07-08）**：input 方向對了，但**沒限 `dest_port`**
> 就擋掉「lan→路由器的**所有** v6 tcp/udp」——**含 DHCPv6(udp 547)**。Android Wi-Fi
> 連線會同時試 v4 DHCP + v6 配置，v6 的 DHCPv6 被 REJECT 卡住 → **整個配置卡住，連 v4 IP
> 都拿不到**。**必須加 `dest_port='53'`** 只擋 v6 DNS，放行 DHCPv6。教訓：擋 input 也要限 port，
> 別把裝置拿 IP 需要的 v6 服務(DHCPv6 547、RA)一起擋了。

---

## 一句話記法

| 方向 | 白話 | 典型例子 |
|------|------|---------|
| **傳入 input** | 有人來敲**路由器自己**的門 | 問路由器 DNS、開 LuCI、ssh 進來 |
| **傳出 output** | **路由器自己**出門 | AGH 查上游、curl、sync 下載 |
| **轉送 forward** | 有人**借道穿過**路由器去別處 | 上網、看 Netflix、走 VPN |

> 設規則前先問自己：**我要擋的封包，目的地是路由器自己（input）、還是要穿過去別的地方（forward）？**
> 想擋「連路由器的服務」用 input；想擋「上網/轉發」用 forward。搞錯方向 = 擋錯東西。
