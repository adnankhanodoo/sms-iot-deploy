#!/bin/bash
# SMS Sentinel AI — Router Health Watchdog v2.1

LOG="/home/sms/sms-iot/scripts/router-watchdog.log"
SCORE_FILE="/home/sms/sms-iot/scripts/.router_health"
REBOOT_COUNT_FILE="/home/sms/sms-iot/scripts/.router_reboot_count"
LAST_REBOOT_FILE="/home/sms/sms-iot/scripts/.router_last_reboot"
ROUTER="192.168.2.1"
CLOUD="100.84.164.127"
WIFI_IFACE="wlp2s0"
WIFI_CONN="Jazz 4G CPE_F5EC"
REBOOT_THRESHOLD=15
MAX_REBOOTS_PER_HOUR=2
MIN_REBOOT_GAP=600

[ -f $SCORE_FILE ] || echo "0" > $SCORE_FILE
[ -f $REBOOT_COUNT_FILE ] || echo "0" > $REBOOT_COUNT_FILE
[ -f $LAST_REBOOT_FILE ] || echo "0" > $LAST_REBOOT_FILE

SCORE=$(cat $SCORE_FILE)
REBOOT_COUNT=$(cat $REBOOT_COUNT_FILE)
LAST_REBOOT=$(cat $LAST_REBOOT_FILE)
NOW=$(date +%s)

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> $LOG; }

[ $((NOW - LAST_REBOOT)) -gt 3600 ] && echo "0" > $REBOOT_COUNT_FILE && REBOOT_COUNT=0

WIFI_STATE=$(nmcli -t -f DEVICE,STATE dev | grep "$WIFI_IFACE" | cut -d: -f2)
if [ "$WIFI_STATE" != "connected" ]; then
    log "WiFi not connected ($WIFI_STATE) — reconnecting, skipping router check"
    sudo nmcli connection up "$WIFI_CONN" >> $LOG 2>&1
    echo "0" > $SCORE_FILE
    exit 0
fi

if ! ping -c1 -W2 $ROUTER > /dev/null 2>&1; then
    SCORE=$((SCORE + 3))
    log "Router unreachable (+3) score=$SCORE"
else
    [ $SCORE -gt 0 ] && SCORE=$((SCORE - 1))
fi

if ! ping -c2 -W3 8.8.8.8 > /dev/null 2>&1; then
    SCORE=$((SCORE + 3))
    log "8.8.8.8 FAIL (+3) score=$SCORE"
else
    [ $SCORE -gt 0 ] && SCORE=$((SCORE - 2))
fi

if ! timeout 4 nslookup google.com > /dev/null 2>&1; then
    SCORE=$((SCORE + 2))
    log "DNS FAIL (+2) score=$SCORE"
else
    [ $SCORE -gt 0 ] && SCORE=$((SCORE - 1))
fi

if ! ping -c1 -W3 $CLOUD > /dev/null 2>&1; then
    SCORE=$((SCORE + 2))
    log "Cloud FAIL (+2) score=$SCORE"
else
    [ $SCORE -gt 0 ] && SCORE=$((SCORE - 1))
fi

[ $SCORE -lt 0 ] && SCORE=0
[ $SCORE -gt 30 ] && SCORE=30
echo $SCORE > $SCORE_FILE

if [ $SCORE -eq 0 ]; then
    log "OK score=0"
elif [ $SCORE -lt $REBOOT_THRESHOLD ]; then
    log "WARNING score=$SCORE degrading — monitoring"
fi

if [ $SCORE -ge $REBOOT_THRESHOLD ]; then
    TIME_SINCE_REBOOT=$((NOW - LAST_REBOOT))
    if [ $TIME_SINCE_REBOOT -lt $MIN_REBOOT_GAP ]; then
        log "Score=$SCORE but last reboot ${TIME_SINCE_REBOOT}s ago — min gap not reached"
        exit 0
    fi
    if [ $REBOOT_COUNT -ge $MAX_REBOOTS_PER_HOUR ]; then
        log "Score=$SCORE but max reboots/hr reached — skipping"
        exit 0
    fi
    log "CRITICAL score=$SCORE — rebooting router (reboot #$((REBOOT_COUNT+1)) this hour)"
    RESULT=$(curl -s --max-time 5 "http://$ROUTER/goform/goform_set_cmd_process" \
        -d "isTest=false&goformId=REBOOT_DEVICE" \
        -H "Referer: http://$ROUTER/index.html" 2>/dev/null)
    if echo "$RESULT" | grep -q "success"; then
        log "Router reboot SUCCESS"
        echo "0" > $SCORE_FILE
        echo $((REBOOT_COUNT + 1)) > $REBOOT_COUNT_FILE
        echo $NOW > $LAST_REBOOT_FILE
        log "Waiting 60s for recovery..."
        sleep 60
        ping -c2 -W3 8.8.8.8 > /dev/null 2>&1 && log "Internet restored ✅" || log "Still recovering..."
    else
        log "Router reboot FAILED — $RESULT"
    fi
fi

tail -300 $LOG > ${LOG}.tmp && mv ${LOG}.tmp $LOG
