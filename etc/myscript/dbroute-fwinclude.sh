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
    ( sleep 5 && service dnsmasq restart && sleep 3 && /etc/myscript/dbroute-refresh.sh && logger -t dbroute "nft sets refreshed (firewall include)" ) &
fi
