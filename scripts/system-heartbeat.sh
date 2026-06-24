#!/bin/bash
ASSET_ID="2j2lzTr2vnzh3odJieos57"
REALM="master"
CLIENT_ID="systemhealth"
MQTT_USER="master:systemhealth"
MQTT_PASS="kHiLElOeAeFfL9QnZt6Fo2UujsGSUY01"
MQTT_PORT="1883"

# Auto-detect manager IP every time — survives Docker restarts
get_mqtt_host() {
    docker inspect smarthome-manager 2>/dev/null | \
        python3 -c "import sys,json; data=json.load(sys.stdin); \
        print(list(data[0]['NetworkSettings']['Networks'].values())[0]['IPAddress'])" 2>/dev/null
}

pub() {
    local HOST=$(get_mqtt_host)
    mosquitto_pub -h $HOST -p $MQTT_PORT \
        -u "$MQTT_USER" -P "$MQTT_PASS" -i "$CLIENT_ID" \
        -t "$REALM/$CLIENT_ID/writeattributevalue/$1/$ASSET_ID" \
        -m "$2"
}

while true; do
    CPU_TEMP=$(sensors | grep "Package id 0" | awk '{print $4}' | tr -d '+°C')
    CPU_LOAD=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
    MEM_FREE=$(free -m | awk 'NR==2{print $4}')
    UPTIME_SEC=$(cat /proc/uptime | awk '{print int($1)}')
    DISK_USE=$(df / | awk 'NR==2{print $5}' | tr -d '%')
    LAST_SEEN=$(date '+%Y-%m-%d %H:%M:%S PKT')

    pub "temperature" "$CPU_TEMP"
    pub "cpuLoad" "$CPU_LOAD"
    pub "memFreeMb" "$MEM_FREE"
    pub "uptimeSec" "$UPTIME_SEC"
    pub "diskPercent" "$DISK_USE"
    pub "lastSeen" "\"$LAST_SEEN\""

    echo "✅ Heartbeat: temp=${CPU_TEMP}°C load=${CPU_LOAD} mem=${MEM_FREE}MB disk=${DISK_USE}%"
    sleep 60
done
