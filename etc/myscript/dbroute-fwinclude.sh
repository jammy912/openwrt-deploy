#!/bin/sh
# firewall include �X �C�� firewall restart/reload �ɦ۰ʸ��J dbroute nft �W�h
NFT_FILE="/etc/myscript/dbroute.nft"

# �ˬd chain �̬O�_�� mark �W�h�]���O�u�ˬd chain �s�b�^
if nft list chain inet fw4 domain_prerouting 2>/dev/null | grep -q "meta mark set"; then
    # self-heal: firewall reload has been observed to wipe prio-100 DBR ip rules
    # while the nft chain survives. dbroute-setup is idempotent and cheap, so
    # re-run it on every firewall event to restore lost rules automatically.
    /etc/myscript/dbroute-setup.sh
    logger -t dbroute "nft rules already loaded, setup re-run (firewall include)"
    exit 0
fi

# �R���i��ݯd���� chain/set�A�A���s���J����W�h
nft delete chain inet fw4 domain_prerouting 2>/dev/null
for _set in $(nft list sets inet fw4 2>/dev/null | grep -o 'route_.*_v4'); do
    nft delete set inet fw4 "$_set" 2>/dev/null
done

if [ -f "$NFT_FILE" ]; then
    nft -f "$NFT_FILE" 2>/dev/null && logger -t dbroute "nft rules loaded (firewall include)" || logger -t dbroute "nft rules load failed (firewall include)"
    # self-heal: rebuild DBR ip rules too (see comment above)
    /etc/myscript/dbroute-setup.sh
    # �I���G���� dnsmasq �������s���J nftset ���O�A�A refresh ��R
    # 2026-10-22 throttle+lock: this block restarts dnsmasq, which itself emits a
    #   network event that can re-trigger the firewall reload that runs this very
    #   include -- a self-feeding loop. Observed on x60pro: wan6 (proto dhcpv6,
    #   upstream has no IPv6 at all) flapped ~5x/sec and stacked 235 dnsmasq
    #   restart processes, load 7.5 on a 4-core box.
    #   Lock     = never more than one refresh in flight (stops the pile-up).
    #   Throttle = at most once per 60s (stops the rapid re-fire).
    #   Both are purely defensive; a normal single firewall reload behaves as before.
    _dbfw_lock="/tmp/.dbroute_fwinc.lock"
    _dbfw_ts="/tmp/.dbroute_fwinc.ts"
    _dbfw_now=$(date +%s)
    _dbfw_last=$(cat "$_dbfw_ts" 2>/dev/null || echo 0)
    # stale-lock guard: if a previous run was killed before rmdir, free it after 300s
    if [ -d "$_dbfw_lock" ]; then
        _dbfw_lage=$(( _dbfw_now - $(cat "$_dbfw_lock/ts" 2>/dev/null || echo 0) ))
        [ "$_dbfw_lage" -gt 300 ] && rm -rf "$_dbfw_lock" 2>/dev/null
    fi
    if [ $(( _dbfw_now - _dbfw_last )) -lt 60 ]; then
        logger -t dbroute "nftset refresh skipped (throttled, last run $(( _dbfw_now - _dbfw_last ))s ago)"
    elif ! mkdir "$_dbfw_lock" 2>/dev/null; then
        logger -t dbroute "nftset refresh skipped (another refresh still in flight)"
    else
        echo "$_dbfw_now" > "$_dbfw_lock/ts" 2>/dev/null
        echo "$_dbfw_now" > "$_dbfw_ts" 2>/dev/null
        (   sleep 5
            service dnsmasq restart
            sleep 3
            /etc/myscript/dbroute-refresh.sh
            logger -t dbroute "nft sets refreshed (firewall include)"
            rm -rf "$_dbfw_lock" 2>/dev/null
        ) &
    fi
fi
