#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
IP=$(sudo ifconfig wlan1 | grep "inet " | awk -F'[: ]+' '{ print $3 }')
echo "${IP}"

sudo python /data/data/com.termux/files/home/scripts/update_ip.py ${IP} /data/data/com.termux/files/home/.suroot/.homeassistant/.storage/core.config_entries
. "/data/data/com.termux/files/home/.venv/bin/activate"
sudo hass
