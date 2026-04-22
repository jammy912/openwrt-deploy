#!/bin/sh

# 推播公車到站資訊 (TDX API)
# Requires: curl, jq (install via: opkg install curl jq)
#
# 用法: push-businfo.sh [路線] [站名] [方向名稱] [城市] [debug]
#   $1  TARGET_ROUTE      路線編號，預設 307
#   $2  TARGET_STOP       站名，預設 市政府站
#   $3  DIRECTION_INPUT   方向名稱 (如「往板橋」「板橋」)，或代碼 (0/1)，預設 往板橋
#   $4  CITY              TDX 城市代碼，預設 auto (自動偵測: Taipei → NewTaipei)
#                         auto         自動偵測 (依站名比對)
#                         Taipei       台北市    NewTaipei    新北市
#                         Taoyuan      桃園市    Taichung     台中市
#                         Tainan       台南市    Kaohsiung    高雄市
#                         Keelung      基隆市    Hsinchu      新竹市
#                         HsinchuCounty 新竹縣   MiaoliCounty 苗栗縣
#                         ChanghuaCounty 彰化縣  NantouCounty 南投縣
#                         YunlinCounty 雲林縣    ChiayiCounty 嘉義縣
#                         Chiayi       嘉義市    PingtungCounty 屏東縣
#                         YilanCounty  宜蘭縣    HualienCounty 花蓮縣
#                         TaitungCounty 台東縣   KinmenCounty 金門縣
#                         PenghuCounty 澎湖縣    LienchiangCounty 連江縣
#   $5  MAX_MINUTES       到站時間超過此分鐘數則不推播，預設空值(不限制)
#   $6  DEBUG             除錯模式 (0/1)，預設 0
#
# 方向名稱會與 TDX 路線起迄站比對，自動推算方向代碼
# 路線資訊快取於 /tmp/busroute_<路線>_<城市>.cache (24小時)
#
# 範例:
#   push-businfo.sh                                           # 307 市政府站 往板橋 (自動偵測城市)
#   push-businfo.sh 307 "市政府站" "往撫遠街"                   # 307 市政府站 往撫遠街
#   push-businfo.sh 99 "台北車站" "往北投" Taipei              # 明確指定城市
#   push-businfo.sh 307 "市政府站" "往板橋" auto 10            # 超過10分鐘不推播

# 公車到站有時效性,不納入全域 cron 鎖 (被 60 秒鎖卡住會錯過報時)

# Load push notification function
. /etc/myscript/push_notify.inc
PUSH_NAMES="${PUSH_NAMES:-admin}" # 環境變數覆寫，例如 PUSH_NAMES="admin;ann" push-businfo.sh ...
HOSTNAME=""

# --- Configuration ---
SECRET_DIR="/etc/myscript/.secrets"
APP_ID=$(cat "$SECRET_DIR/tdx.appid" 2>/dev/null) || { echo "缺少 $SECRET_DIR/tdx.appid"; exit 1; }
APP_KEY=$(cat "$SECRET_DIR/tdx.appkey" 2>/dev/null) || { echo "缺少 $SECRET_DIR/tdx.appkey"; exit 1; }

# --- 參數 (可由命令列覆寫) ---
TARGET_ROUTE="${1:-307}"
TARGET_STOP="${2:-市政府站}"
DIRECTION_INPUT="${3:-往板橋}"    # 方向名稱 (如「往板橋」「板橋」) 或代碼 (0/1)
CITY="${4:-auto}"                # TDX 城市代碼，auto=自動偵測
MAX_MINUTES="${5:-}"             # 到站超過此分鐘數不推播，空值=不限制
DEBUG="${6:-0}"
TARGET_DIRECTION=""               # 由 resolve_direction() 自動設定
DIRECTION_TEXT=""

TDX_BASE="https://tdx.transportdata.tw/api/basic/v2/Bus"
AUTH_URL="https://tdx.transportdata.tw/auth/realms/TDXConnect/protocol/openid-connect/token"
# AUTO_CITIES: 自動偵測時依序嘗試的城市 (大台北地區優先)
AUTO_CITIES="Taipei NewTaipei Keelung Taoyuan Hsinchu HsinchuCounty MiaoliCounty Taichung ChanghuaCounty NantouCounty YunlinCounty Chiayi ChiayiCounty Tainan Kaohsiung PingtungCounty YilanCounty HualienCounty TaitungCounty KinmenCounty PenghuCounty LienchiangCounty"

# --- Functions ---

# 查詢指定城市的路線資訊，回傳 dest|dept 或空字串
# $1=token $2=city → stdout: "迄站|起站" 或空
query_route_for_city() {
    local token="$1" city="$2"
    local url="${TDX_BASE}/Route/City/${city}/${TARGET_ROUTE}"
    local temp_file="/tmp/bus_route_$$.dl"

    curl -s -X GET "$url" \
        -H "authorization: Bearer $token" \
        -H "Accept-Encoding: gzip" \
        -o "$temp_file"

    local route_data=$(gunzip -c "$temp_file" 2>/dev/null || cat "$temp_file" 2>/dev/null)
    rm -f "$temp_file"

    [ -z "$route_data" ] && return

    if echo "$route_data" | jq -e 'type == "array"' >/dev/null 2>&1; then
        local dest=$(echo "$route_data" | jq -r "[.[] | select(.RouteName.Zh_tw == \"$TARGET_ROUTE\")] | .[0].DestinationStopNameZh // empty")
        local dept=$(echo "$route_data" | jq -r "[.[] | select(.RouteName.Zh_tw == \"$TARGET_ROUTE\")] | .[0].DepartureStopNameZh // empty")
        if [ -n "$dest" ] || [ -n "$dept" ]; then
            echo "${dest}|${dept}"
        fi
    fi
}

# 從 TDX 查詢路線起迄站，用輸入的方向名稱反查方向代碼
# 快取格式: city|0|往迄站名 / city|1|往起站名 (24小時有效)
# 設定全域變數: TARGET_DIRECTION, DIRECTION_TEXT, CITY
resolve_direction() {
    local token="$1"
    local input="$2"
    local route_cache="/tmp/busroute_${TARGET_ROUTE}.cache"

    # 若輸入是數字 0 或 1，直接當代碼用
    case "$input" in
        0|1)
            TARGET_DIRECTION="$input"
            ;;
        *)
            # 去掉「往」前綴方便比對
            input=$(echo "$input" | sed 's/^往//')
            ;;
    esac

    local dest="" dept="" cached_city=""

    # 檢查快取是否存在且未過期 (86400秒=24小時)
    if [ -f "$route_cache" ]; then
        local cache_age=$(( $(date +%s) - $(date -r "$route_cache" +%s 2>/dev/null || echo 0) ))
        if [ "$cache_age" -lt 86400 ]; then
            cached_city=$(awk -F'|' 'NR==1 {print $1}' "$route_cache")
            dest=$(awk -F'|' '$2==0 {print $3}' "$route_cache" | sed 's/^往//')
            dept=$(awk -F'|' '$2==1 {print $3}' "$route_cache" | sed 's/^往//')
            if [ -n "$cached_city" ] && [ "$CITY" = "auto" ]; then
                CITY="$cached_city"
            fi
        fi
    fi

    # 快取無資料時查 API
    if [ -z "$dest" ] && [ -z "$dept" ]; then
        local result=""
        if [ "$CITY" = "auto" ]; then
            # 自動偵測：依序嘗試城市，找到就停
            for _city in $AUTO_CITIES; do
                if [ "$DEBUG" -eq 1 ]; then
                    echo "Debug: 嘗試城市 $_city ..." >&2
                fi
                result=$(query_route_for_city "$token" "$_city")
                if [ -n "$result" ]; then
                    CITY="$_city"
                    if [ "$DEBUG" -eq 1 ]; then
                        echo "Debug: 偵測到城市 $_city ($result)" >&2
                    fi
                    break
                fi
            done
            if [ "$CITY" = "auto" ]; then
                echo "[WARN] 在 $AUTO_CITIES 中找不到路線 $TARGET_ROUTE" >&2
                CITY="Taipei"
            fi
        else
            result=$(query_route_for_city "$token" "$CITY")
        fi

        if [ "$DEBUG" -eq 1 ]; then
            echo "Debug: City=$CITY, route result=$result" >&2
        fi

        dest=$(echo "$result" | cut -d'|' -f1)
        dept=$(echo "$result" | cut -d'|' -f2)

        # 寫入快取 (含城市)
        {
            [ -n "$dest" ] && echo "${CITY}|0|往${dest}"
            [ -n "$dept" ] && echo "${CITY}|1|往${dept}"
        } > "$route_cache"
    fi

    # 若已有數字代碼，只需填方向名稱
    if [ -n "$TARGET_DIRECTION" ]; then
        if [ "$TARGET_DIRECTION" -eq 0 ]; then
            DIRECTION_TEXT="往${dest:-?}"
        else
            DIRECTION_TEXT="往${dept:-?}"
        fi
        return
    fi

    # 用輸入名稱模糊比對起迄站 (如「板橋」匹配「板橋」)
    if [ -n "$dest" ] && echo "$dest" | grep -qi "$input"; then
        TARGET_DIRECTION=0
        DIRECTION_TEXT="往${dest}"
    elif [ -n "$dept" ] && echo "$dept" | grep -qi "$input"; then
        TARGET_DIRECTION=1
        DIRECTION_TEXT="往${dept}"
    else
        echo "[WARN] 無法匹配方向「$input」(起站=$dept, 迄站=$dest)，預設方向0" >&2
        TARGET_DIRECTION=0
        DIRECTION_TEXT="往${dest:-?}"
    fi
}

get_access_token() {
    local response
    response=$(curl -s -X POST "$AUTH_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=client_credentials" \
        -d "client_id=$APP_ID" \
        -d "client_secret=$APP_KEY")

    if [ $? -ne 0 ]; then
        echo "Authentication Error: Failed to connect to TDX API" >&2
        return 1
    fi

    local token
    token=$(echo "$response" | jq -r '.access_token // empty')

    if [ -z "$token" ]; then
        echo "Authentication Error: Failed to obtain access token" >&2
        return 1
    fi

    echo "$token"
}

fetch_bus_data() {
    local token="$1"
    local response
    local temp_file="/tmp/bus_data_$$.tmp"

    # Download gzip data to temp file (CITY 在 resolve_direction 後才確定)
    local data_url="${TDX_BASE}/EstimatedTimeOfArrival/City/${CITY}/${TARGET_ROUTE}"
    curl -s -X GET "$data_url" \
        -H "authorization: Bearer $token" \
        -H "Accept-Encoding: gzip" \
        -o "$temp_file"

    if [ $? -ne 0 ]; then
        rm -f "$temp_file"
        echo "Data Fetching Error: Failed to fetch bus data" >&2
        return 1
    fi

    # 嘗試 gunzip，失敗則當作純 JSON
    response=$(gunzip -c "$temp_file" 2>/dev/null || cat "$temp_file" 2>/dev/null)
    rm -f "$temp_file"

    if [ -z "$response" ]; then
        echo "Data Fetching Error: Empty response" >&2
        return 1
    fi

    # Debug: Save response to file if DEBUG=1
    if [ "$DEBUG" -eq 1 ]; then
        echo "$response" > /tmp/bus_response.json
        echo "Debug: Response saved to /tmp/bus_response.json" >&2
    fi

    # Validate JSON
    if ! echo "$response" | jq empty 2>/dev/null; then
        echo "Data Fetching Error: Invalid JSON response" >&2
        if [ "$DEBUG" -eq 1 ]; then
            echo "Response (first 500 chars): $(echo "$response" | head -c 500)" >&2
        fi
        return 1
    fi

    echo "$response"
}

display_bus_eta() {
    local bus_data="$1"

    # Check if bus_data is valid JSON array
    if ! echo "$bus_data" | jq -e 'type == "array"' >/dev/null 2>&1; then
        push_notify "$TARGET_ROUTE$DIRECTION_TEXT 資料格式錯誤 @$TARGET_STOP"
        return 1
    fi

    # Filter bus data - get first matching record only
    local bus
    bus=$(echo "$bus_data" | jq -c "[.[] | select(.StopName.Zh_tw == \"$TARGET_STOP\" and .Direction == $TARGET_DIRECTION)] | sort_by(.EstimateTime // 999999) | .[0]")

    if [ "$bus" = "null" ] || [ -z "$bus" ]; then
        # return 2 表示找不到站，讓 main 可以觸發自動搜尋
        return 2
    fi

    local eta_seconds
    local stop_status

    eta_seconds=$(echo "$bus" | jq -r '.EstimateTime // "null"')
    stop_status=$(echo "$bus" | jq -r '.StopStatus // 0')

    local eta_text

    if [ "$eta_seconds" = "null" ] || [ -z "$eta_seconds" ]; then
        case $stop_status in
            1) eta_text="尚未發車" ;;
            3) eta_text="末班車已過" ;;
            *) eta_text="等待發車" ;;
        esac
    else
        # Safely handle numeric comparisons
        if [ "$eta_seconds" -eq 0 ] 2>/dev/null; then
            eta_text="進站中"
        elif [ "$eta_seconds" -lt 60 ] 2>/dev/null; then
            eta_text="即將到達(${eta_seconds}秒)"
        else
            local minutes=$((eta_seconds / 60))
            local seconds=$((eta_seconds % 60))
            eta_text="${minutes}分${seconds}秒"
        fi
    fi

    # 超過指定分鐘數則不推播
    if [ -n "$MAX_MINUTES" ] && [ "$eta_seconds" != "null" ] && [ -n "$eta_seconds" ]; then
        local max_sec=$((MAX_MINUTES * 60))
        if [ "$eta_seconds" -gt "$max_sec" ] 2>/dev/null; then
            [ "$DEBUG" -eq 1 ] && echo "Debug: ETA ${eta_seconds}s > ${max_sec}s, 不推播" >&2
            return 0
        fi
    fi

    # Send push notification
    push_notify "$TARGET_ROUTE$DIRECTION_TEXT $eta_text @$TARGET_STOP"
}

# --- Main Execution ---

main() {
    # 非主gw 不需要查公車
    GW_TYPE=$(cat /etc/myscript/.mesh_gw_type 2>/dev/null)
    [ "$GW_TYPE" != "主gw" ] && exit 0

    # Check dependencies
    if ! command -v curl >/dev/null 2>&1; then
        push_notify "$TARGET_ROUTE$DIRECTION_TEXT @$TARGET_STOP curl 未安裝"
        exit 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        push_notify "$TARGET_ROUTE$DIRECTION_TEXT @$TARGET_STOP jq 未安裝"
        exit 1
    fi

    # Get access token
    local access_token
    access_token=$(get_access_token)

    if [ -z "$access_token" ] || [ "$access_token" = "null" ]; then
        push_notify "$TARGET_ROUTE$DIRECTION_TEXT @$TARGET_STOP 驗證失敗"
        exit 1
    fi

    if [ "$DEBUG" -eq 1 ]; then
        echo "Debug: Access token obtained successfully" >&2
    fi

    # 解析方向：名稱 → 代碼 + 完整方向名稱
    local was_auto="$CITY"
    resolve_direction "$access_token" "$DIRECTION_INPUT"
    if [ "$DEBUG" -eq 1 ]; then
        echo "Debug: Direction=$TARGET_DIRECTION, Text=$DIRECTION_TEXT" >&2
    fi

    # 自動偵測時推播完整參數，方便下次直接填入
    if [ "$was_auto" = "auto" ] && [ "$CITY" != "auto" ]; then
        push_notify "[自動偵測] 建議參數: push-businfo.sh $TARGET_ROUTE \"$TARGET_STOP\" \"$DIRECTION_TEXT\" $CITY"
    fi

    # Fetch bus data
    local bus_data
    bus_data=$(fetch_bus_data "$access_token")

    if [ $? -ne 0 ] || [ -z "$bus_data" ]; then
        push_notify "$TARGET_ROUTE$DIRECTION_TEXT @$TARGET_STOP 資料取得失敗"
        exit 1
    fi

    if [ "$DEBUG" -eq 1 ]; then
        echo "Debug: Bus data fetched successfully" >&2
        echo "Debug: Data length: $(echo "$bus_data" | wc -c) bytes" >&2
    fi

    # Display results and send push notification
    display_bus_eta "$bus_data"
    local eta_result=$?

    # 找不到站時，自動遍歷所有城市重新查
    if [ $eta_result -eq 2 ]; then
        local original_city="$CITY"
        local found=0
        if [ "$DEBUG" -eq 1 ]; then
            echo "Debug: $original_city 找不到站 $TARGET_STOP，開始搜尋所有城市..." >&2
        fi
        for try_city in $AUTO_CITIES; do
            [ "$try_city" = "$original_city" ] && continue
            # 先查路線是否存在
            local try_result=$(query_route_for_city "$access_token" "$try_city")
            [ -z "$try_result" ] && continue
            # 路線存在，查到站資訊
            CITY="$try_city"
            # 重新解析方向
            rm -f "/tmp/busroute_${TARGET_ROUTE}.cache"
            resolve_direction "$access_token" "$DIRECTION_INPUT"
            local try_data=$(fetch_bus_data "$access_token")
            [ -z "$try_data" ] && continue
            display_bus_eta "$try_data"
            if [ $? -ne 2 ]; then
                found=1
                # 城市名稱對照
                local city_name=""
                case "$try_city" in
                    Taipei) city_name="台北市" ;; NewTaipei) city_name="新北市" ;;
                    Keelung) city_name="基隆市" ;; Taoyuan) city_name="桃園市" ;;
                    Hsinchu) city_name="新竹市" ;; HsinchuCounty) city_name="新竹縣" ;;
                    MiaoliCounty) city_name="苗栗縣" ;; Taichung) city_name="台中市" ;;
                    ChanghuaCounty) city_name="彰化縣" ;; NantouCounty) city_name="南投縣" ;;
                    YunlinCounty) city_name="雲林縣" ;; Chiayi) city_name="嘉義市" ;;
                    ChiayiCounty) city_name="嘉義縣" ;; Tainan) city_name="台南市" ;;
                    Kaohsiung) city_name="高雄市" ;; PingtungCounty) city_name="屏東縣" ;;
                    YilanCounty) city_name="宜蘭縣" ;; HualienCounty) city_name="花蓮縣" ;;
                    TaitungCounty) city_name="台東縣" ;; KinmenCounty) city_name="金門縣" ;;
                    PenghuCounty) city_name="澎湖縣" ;; LienchiangCounty) city_name="連江縣" ;;
                    *) city_name="$try_city" ;;
                esac
                push_notify "[提示] $TARGET_ROUTE 城市設定有誤，正確城市: $city_name ($try_city)"
                break
            fi
        done
        if [ $found -eq 0 ]; then
            push_notify "$TARGET_ROUTE$DIRECTION_TEXT 無車輛資訊 @$TARGET_STOP (已搜尋所有城市)"
        fi
    fi
}

# Run main function
main
