# LINE 推播（Messaging API）與 LineCMD 遠端維運

> 2026-07-06/07。LINE Notify 於 2025-03-31 停服,推播遷 Messaging API;並新增
> LineCMD:從 Google Sheet 下發白名單維運指令給路由器執行。這份記兩者的機制與坑。

---

## 一、推播系統（push-notify.inc）

### 多通道自動分流：靠 pushkey **內容格式**判斷通道

`push_notify` 讀 `PUSH_NAMES`(如 admin) → 取 `.secrets/pushkey.<name>` 的內容 →
**依內容格式自動選通道**:

| pushkey 內容格式 | 通道 |
|-----------------|------|
| `PD` 開頭 | PushDeer |
| `U`/`C`/`R` + 32 hex(userId/groupId/roomId) | **LINE Messaging API**(需 `.secrets/line.token`) |
| 40+ 字元英數 | 舊 LINE Notify token → **只印 WARN(已停服)** |

好處:混搭自動成立(某人 PushDeer、某人 LINE),呼叫端不用改。

### line.token（Channel access token）由 Sheet 下發

- LINE Developers Console 建 Messaging API channel → 發 Channel access token。
- **Sheet 的 PushKey 表加一筆 `name=linetoken`** → sync-googleconfig 特例寫成
  `.secrets/line.token`(不是 pushkey.linetoken)→ **Sheet 即備份 + 全機隊自動下發**。
- deploy.sh 互動流程也會問 line.token(選填備援)。

### 坑：`.inc` 是函式庫,要 `.` source 不是執行

```sh
# ❌ 錯:直接執行(函式定義在子行程,結束就沒了)
/etc/myscript/push-notify.inc && push_notify "x"    # push_notify: not found

# ✅ 對:source 載入當前 shell + 設 PUSH_NAMES
. /etc/myscript/push-notify.inc && PUSH_NAMES=admin && push_notify "x"
```
deploy 版靠 `PUSH_NAMES` 讀 `.secrets/pushkey.<name>`,**忘了設 PUSH_NAMES → 靜默失敗**
(找不到 key 就 return,不報錯)。cron 裡的溫度通知那行也要 `. push-notify.inc && PUSH_NAMES=admin`。

### 檔名一致性

deploy 體系用 **`push-notify.inc`(連字號)**。獨立機器(如 .6)舊版是 `push_notify.inc`
(底線)——已統一成連字號,且建 `.secrets/pushkey.admin`(PushDeer key)。

---

## 二、LineCMD：Sheet 下發白名單維運指令

### 用途

從 Google Sheet 的「LineCMD」分頁下指令(如 reboot/dbr-refresh/wg-restart),sync 時
路由器執行,結果推播回報。**遠端維運**用。

### 安全模型（★核心，勿破壞）

**Sheet 只填「動作代號」,真正指令由 `linecmd-handler.sh` 的 `case` 白名單決定。**
Sheet 就算被塞 `rm -rf /` 也對應不到 case → 忽略 → **無 RCE**。arg 一律 `"$@"` 引用,
**嚴禁 eval/sh -c 任何來自 Sheet 的字串**。

### 資料流

```
Sheet「LineCMD」分頁(欄: A=時間戳 B=arg C=action D=status)
  │ GAS 只輸出 status=="等待執行" 的列成 config linecmd(小寫、option 值加單引號)
  │ 輸出後 setValue D 欄「已下發」防重複
  ▼
sync-googleconfig 解密驗證 → 解析 linecmd 段
  → 呼叫 /etc/myscript/linecmd-handler.sh <action> [args...]
  → handler case 白名單比對 → 執行 → push_notify ✅/❌
```

### 白名單（改 linecmd-handler.sh 的 case 即可增修，走 sync-deploy 下發）

`reboot` / `sync-force` / `wg-restart`(需 arg=wgN,含介面防呆) / `dbr-refresh` /
`dbr-setup` / `pbr-reload` / `fw-reload` / `dnsmasq-restart`。

### 多參數

Sheet 用多個 `list arg`(依序成 handler 的 $1 $2 ...);`option arg` 單筆仍相容。

### 坑與注意

- **不做路由器端 id 去重**:靠 GAS 狀態欄「等待執行→已下發」單次觸發。
- ⚠️ **多機隊只有第一台收到**:狀態欄「已下發」被第一台 sync 改掉,其他台就讀不到。
  若某動作要全機隊執行,需 per-host 狀態或不標記。
- **每分鐘 cron sync 持鎖久**:手動 sync/dump 常撞鎖空退。別手動測,填 Sheet 等一分鐘
  內 cron 自動執行 + LINE 推播確認。
- **GAS 端常見錯**:`config LineCMD` 大寫(要小寫 linecmd)、option 值沒加單引號、
  `&`(要 `&&`)、`output+="\n"` 放 if 外。
- **格式驗證**:解密後必須 `config linecmd` 開頭 + tab 縮排,否則被 sync 格式驗證擋下。

### 相關記憶

`memory/line-push-migration.md`、`memory/linecmd-remote-action.md`。
