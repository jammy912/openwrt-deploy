# ZeroTier 備援 VPN：自架 controller + ztncui + 加節點 SOP

> 2026-07-07 建置。主線是 tailscale/headscale,ZeroTier 當**第二條進機路**(主線掛了
> 還能 ssh 進路由器維運)。純備援用途:**只連機器本身,不橋接家用 LAN**。
> 這份記完整建置 + 加節點步驟 + 踩過的坑,避免重建/加節點重踩。

---

## 架構總覽

```
.3 (OCI VM, <.3-ts-ip>)                    家裡路由器
┌──────────────────────────┐              ┌──────────────┐
│ docker: ztncui 容器       │              │ .1 (node <NODE_A>) │
│  = ZeroTier controller    │◀──ZeroTier──▶│   10.147.20.x       │
│  + 網頁管理 UI(:3443)     │   network    │ .5 (node <NODE_B>) │
│ host: 只跑 dockerd        │              │   10.147.20.y       │
│  (不跑 host zerotier)     │              └──────────────┘
└──────────────────────────┘
```

- **Controller + UI**:`.3`(OCI x86_64 VM,OpenWrt 25.12 **用 apk 非 opkg**)。
- **network id**:見 `memory/zerotier-backup-vpn.md`(不寫進公開 repo),名 `vpn-backup`,
  網段 **`10.147.20.0/24`**(pool .10-.200),private。
- **UI**:`https://<.3 tailscale IP>:3443`(走 tailscale,不用開 OCI port),admin / 密碼見
  `.3` 的 `docker run` 的 `-e ZTNCUI_PASSWD`。
- **成員**:`.1`、`.5` 各拿一個 `10.147.20.x`,已授權。node ID / 實際 IP 見 memory。`.3`
  **不當成員**(見坑 4)。

---

## 三個踩過的坑（重建/排錯必看）

### 🔴 坑 1：Docker 跑 ZeroTier 必須 `--network host`
bridge 模式下容器內 zerotier **連不到 planet**(peer 全 RELAY/latency=-1)→ 節點找不到
controller。必須 `--network host`。但 host 模式會**撞 host 埠**:ztncui 內部用 3000,
撞 AGH(佔 3000)→ 容器反覆 FATAL。解法:`-e HTTP_PORT=3080` 避開。

### 🔴 坑 2：OpenWrt zerotier 資料在 `/tmp/lib` 不是 `/var/lib`
OpenWrt 的 zerotier 套件工作目錄是 **`/tmp/lib/zerotier-one`**(tmpfs),`zerotier-cli`
預設找 `/var/lib` 會報 `missing port`。要 `zerotier-cli -p$(cat /tmp/lib/zerotier-one/zerotier-one.port) ...`。

### 🔴 坑 3：zt 介面必須加進 firewall zone,否則封包被 drop
OpenWrt 對「不屬任何 zone 的介面」預設 drop。join 成功、有 IP,但 ping/ssh 不通 →
就是 zt 介面(`ztxxxx`)沒進 zone。建一個 `ztvpn` zone(input=ACCEPT)收它。

### 🔴 坑 4：controller 兼 member 建不出介面(所以 .3 不當成員)
`.3` 容器內 zerotier 是 ztncui image 的「純 controller」設計,自己 join 自己管的網路
時建不出 tap 介面(缺 tun/NET_ADMIN,加了也不穩)。**.3 走 tailscale 連即可**(OCI 公網
VM,tailscale 幾乎不會連不到,且 .3 掛了 ZeroTier 也沒 controller,雞生蛋)。

---

## 加一個新節點 SOP（OpenWrt 路由器）

```sh
# 1. 裝 zerotier(apk 或 opkg,看該機)
apk add zerotier            # 或 opkg install zerotier

# 2. uci 方式 join(★用 uci 不要用 zerotier-cli join——後者不持久,
#    重開機會被 uci 覆蓋,還會退回 earth 測試網)
uci set zerotier.global.enabled='1'
uci delete zerotier.earth 2>/dev/null        # 清套件預設的 earth 測試網
uci set zerotier.vpnbackup=network
uci set zerotier.vpnbackup.id='<NETWORK_ID>'
uci set zerotier.vpnbackup.allow_managed='1'
uci set zerotier.vpnbackup.allow_global='0'
uci set zerotier.vpnbackup.allow_default='0'
uci commit zerotier
/etc/init.d/zerotier enable
/etc/init.d/zerotier restart
sleep 8

# 3. 拿這台 node ID(等下去 controller 授權)
PORT=$(cat /tmp/lib/zerotier-one/zerotier-one.port)
zerotier-cli -p$PORT info      # 第三欄 = node ID

# 4. zt 介面加進 firewall zone(★否則封包被 drop,ping/ssh 不通)
ZTIF=$(ip -4 addr show | grep -oE 'zt[a-z0-9]+' | head -1)
uci show firewall | grep -q "name='ztvpn'" || {
  uci add firewall zone
  uci set firewall.@zone[-1].name='ztvpn'
  uci set firewall.@zone[-1].input='ACCEPT'
  uci set firewall.@zone[-1].output='ACCEPT'
  uci set firewall.@zone[-1].forward='REJECT'
  uci set firewall.@zone[-1].device="$ZTIF"
  uci commit firewall; /etc/init.d/firewall reload; }

# 5. RAM overlay 機器落地(見 ram-overlay-sync-flash.md)
/etc/myscript/sync-ram2flash.sh
```

**然後在 controller(.3)授權這個 node**(private 網路必須授權才拿 IP):
- ztncui UI:`https://<.3-ts-ip>:3443` → vpn-backup 網路 → Members → 找到 node → 打勾 Authorized
- 或 CLI:
  ```sh
  ssh root@<.3-ts-ip>   # -i id_ed25519_openwrt
  TOKEN=$(docker exec ztncui cat /var/lib/zerotier-one/authtoken.secret)
  docker exec ztncui curl -s -X POST -H "X-ZT1-Auth: $TOKEN" \
    -d '{"authorized":true}' \
    http://localhost:9993/controller/network/<NETWORK_ID>/member/<NODEID>
  ```

授權後幾秒節點拿到 `10.147.20.x`,`zerotier-cli -p$PORT listnetworks` 狀態變 `OK`。

## 驗證

```sh
# 從一台 ping 另一台的 ZeroTier IP
ping 10.147.20.x      # .1 → .5
ssh root@10.147.20.x  # 備援進機
```

## OCI port

目前**不用開**(UDP 打洞成功、UI 走 tailscale)。除非:
- 節點打洞退化成 RELAY(慢)→ 開 OCI **UDP 9993**(入向)
- 要從公網(非 tailscale)連 UI → 開 OCI **TCP 3443**

## 這些是手動操作，不在 git repo

ZeroTier 全靠手動 uci/docker,**不隨 sync-deploy**。加節點照上面 SOP。相關記憶:
`memory/zerotier-backup-vpn.md`。
