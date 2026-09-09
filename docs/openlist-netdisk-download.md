# OpenList 網盤下載（`.4` RAX3000M）

夸克網盤 → SSD 暫存 → 8TB 歸檔。容器跑在內部 flash，下載寫外接碟。

## 建立容器

```sh
docker run -d --restart=unless-stopped --name openlist \
  --dns 192.168.1.1 --dns 1.1.1.1 \
  -v /srv/openlist/data:/opt/openlist/data \
  -p 5244:5244 \
  openlistteam/openlist:latest
```

UI `http://<路由器IP>:5244`，密碼存 `/etc/myscript/.secrets/openlist.pass`
（**用 `printf` 寫入不要 `echo`**，多一個換行密碼就錯）。

### ⚠️ `-p` 一定要綁 `0.0.0.0`，不要綁 LAN IP

**不要寫 `-p 192.168.1.4:5244`。** 這台是 auto-role 管理的 mesh 節點，
接手主 gw 時 LAN IP 會從 `192.168.1.4` 變成 `192.168.1.1`，而容器的
`-p` 綁定是建立當下就寫死的：

```
DNAT 規則:     dst 192.168.1.4  tcp dpt:5244 → 172.17.0.2:5244
docker-proxy:  -host-ip 192.168.1.4 -host-port 5244
```

兩者都指向一個**已經不存在於本機**的位址 → 所有連線回 HTTP 000 →
`openlist-sync.sh` 每輪都「登入失敗 — OpenList 沒回應或密碼錯誤」，
下載整整停擺（實測 2026-09-09，停了一小時才發現）。

**容器本身完全正常**，直連 `172.17.0.2:5244` 回 HTTP 200、容器內
`/ping` 回 `pong` —— 壞的只是宿主到容器的 port 轉發，很容易誤判成
容器掛了而去重啟它（沒有用）。

★ 配套：`openlist-sync.sh` 的 `OL_HOST` 用 **`http://127.0.0.1:5244`**，
與 LAN IP 完全脫鉤。

### 診斷指令

```sh
docker port openlist                    # 看綁在哪個 IP
ps w | grep docker-proxy                # -host-ip 是不是現在的 IP
curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 http://127.0.0.1:5244/ping
```

## 容器踩過的坑

- **以 uid 1001 執行**，不是 root。宿主目錄要 `chown -R 1001:1001`，
  否則 crash loop 報 `does not have write permissions`。
  `-e PUID=0` 對 v4.1.0 之後的版本無效。
- **DNS 不能用 Tailscale MagicDNS**：Docker 抄宿主 `/etc/resolv.conf`，
  而那被 tailscale 接管只有 `100.100.100.100`，那位址只在宿主 netns
  有效，容器連不到。★ 明確 `--dns` 指到 **LAN 上「另一台」**
  （指本機 LAN IP 屬 input 鏈走不通）。
- **升級後 storage driver 會變**（原生 `overlayfs`），舊的
  `fuse-overlayfs` 快照會噴 `failed to mount ... invalid argument`。
  ★ 清掉 `/opt/docker` 重來 + `uci set dockerd.globals.storage_driver="fuse-overlayfs"`。

## 資料備份

資料庫（含夸克 Cookie）在 `/srv/openlist/data`，只有幾百 KB：

```sh
tar czf /srv/share/USB/SSD/openlist-data-$(date +%Y%m%d-%H%M).tar.gz \
    -C /srv/openlist data
```

還原後**夸克 Cookie 與儲存設定完整保留，不用重撈**（實測 25.12.5 升級後
儲存狀態直接回到 `work`）。

## 夸克儲存設定的兩個雷

- `use_transcoding_address=true` → 取直鏈回 `plf_invalid`（轉碼地址是給
  線上播放用的，不能當下載直鏈）
- `only_list_video_file=true` → 隱藏所有非影片

兩個都要關。改設定要用 jq 改 `addition` 這個「字串化的 JSON」：

```sh
jq -c ".data | .addition = (.addition | fromjson | .xxx=false | tojson)"
```

## 相關

- 同步腳本：`etc/myscript/openlist-sync.sh`（cron `*/10`，三個位置參數：來源／歸檔／暫存）
- Docker 防火牆兩個坑見 [deployment.md](deployment.md) 與 `etc/myscript/docker-lan-forward.sh`
