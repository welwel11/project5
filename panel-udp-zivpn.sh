#!/bin/bash

# ==============================
# ZIVPN - PANEL USER UDP (RCLONE ONLY BACKUP)
# ==============================

CONFIG_FILE="/etc/zivpn/config.json"
USER_DB="/etc/zivpn/users.db"
CONF_FILE="/etc/zivpn.conf"

RCLONE_CONF="/root/.config/rclone/rclone.conf"
RCLONE_REMOTE_DEFAULT="gdrive:zivpn-backup"

RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
RESET="\033[0m"

clear

command -v jq >/dev/null 2>&1 || {
  echo -e "${RED}jq belum terinstall. Jalankan: apt install jq -y${RESET}"
  exit 1
}

mkdir -p /etc/zivpn
[ ! -f "$CONFIG_FILE" ] && echo '{"listen":":5667","cert":"/etc/zivpn/zivpn.crt","key":"/etc/zivpn/zivpn.key","obfs":"zivpn","auth":{"mode":"passwords","config":["zivpn"]}}' > "$CONFIG_FILE"
[ ! -f "$USER_DB" ] && touch "$USER_DB"
[ ! -f "$CONF_FILE" ] && echo 'AUTOCLEAN=OFF' > "$CONF_FILE"

source "$CONF_FILE"

# ==============================
# INSTALL RCLONE
# ==============================
install_rclone() {
apt update -y >/dev/null 2>&1
apt install -y rclone tar gzip >/dev/null 2>&1
mkdir -p /root/.config/rclone
echo -e "${GREEN}rclone berhasil diinstall${RESET}"
echo -e "${YELLOW}Sekarang jalankan perintah: rclone config${RESET}"
read -p "Enter..."
}

check_rclone(){
if [ ! -f "$RCLONE_CONF" ]; then
echo -e "${RED}rclone belum dikonfigurasi!${RESET}"
echo "Jalankan: rclone config"
read -p "Enter..."
return 1
fi
return 0
}

# ==============================
# BACKUP KE CLOUD
# ==============================
backup_cloud(){

check_rclone || return

FILE="/tmp/zivpn-$(date +%Y%m%d-%H%M%S).tar.gz"

tar -czf "$FILE" \
/etc/zivpn/config.json \
/etc/zivpn/users.db \
/etc/zivpn/zivpn.crt \
/etc/zivpn/zivpn.key \
/etc/zivpn.conf 2>/dev/null

echo -e "${CYAN}Upload ke cloud...${RESET}"
rclone copy "$FILE" "$RCLONE_REMOTE_DEFAULT" --progress

rm -f "$FILE"

echo -e "${GREEN}Backup selesai${RESET}"
read -p "Enter..."
}

# ==============================
# RESTORE DARI CLOUD
# ==============================
restore_cloud(){

check_rclone || return

mkdir -p /tmp/zrestore

echo -e "${CYAN}Daftar backup:${RESET}"
rclone lsf "$RCLONE_REMOTE_DEFAULT" | nl

echo
read -p "Nama file backup: " fname
[ -z "$fname" ] && return

rclone copyto "$RCLONE_REMOTE_DEFAULT/$fname" "/tmp/zrestore/$fname" --progress

systemctl stop zivpn.service 2>/dev/null
tar -xzf "/tmp/zrestore/$fname" -C /
systemctl restart zivpn.service 2>/dev/null

rm -rf /tmp/zrestore

echo -e "${GREEN}Restore selesai${RESET}"
read -p "Enter..."
}

# ==============================
# USER MANAGEMENT
# ==============================
add_user(){
echo -e "${CYAN}Buat akun baru${RESET}"

read -p "Password : " pass
[[ -z "$pass" ]] && echo "Kosong!" && return

read -p "Masa aktif (hari): " days
exp_date=$(date -d "+$days days" +%Y-%m-%d)

jq --arg pw "$pass" '.auth.config += [$pw]' "$CONFIG_FILE" > temp && mv temp "$CONFIG_FILE"
echo "$pass | $exp_date" >> "$USER_DB"

systemctl restart zivpn.service
echo -e "${GREEN}User aktif sampai $exp_date${RESET}"
read -p "Enter..."
}

list_users(){
echo
printf "%-4s %-20s %-12s %-10s\n" "ID" "PASSWORD" "EXPIRED" "STATUS"

i=1
today=$(date +%Y-%m-%d)

while IFS='|' read -r pass exp; do
pass=$(echo "$pass"|xargs)
exp=$(echo "$exp"|xargs)

[ -z "$pass" ] && continue

if [[ "$exp" < "$today" ]]; then
status="EXPIRED"
else
status="AKTIF"
fi

printf "%-4s %-20s %-12s %-10s\n" "$i" "$pass" "$exp" "$status"
((i++))
done < "$USER_DB"
echo
}

remove_user(){
list_users
read -p "ID: " id
sel_pass=$(sed -n "${id}p" "$USER_DB"|cut -d'|' -f1|xargs)
[ -z "$sel_pass" ] && echo "Salah" && return

jq --arg pw "$sel_pass" '.auth.config -= [$pw]' "$CONFIG_FILE" > temp && mv temp "$CONFIG_FILE"
sed -i "/^$sel_pass/d" "$USER_DB"

systemctl restart zivpn.service
echo "User dihapus"
sleep 1
}

# ==============================
# MENU
# ==============================
while true; do

clear
IP=$(curl -s ifconfig.me)

echo "==============================="
echo "        PANEL ZIVPN UDP"
echo "==============================="
echo "IP VPS : $IP"
echo "Port   : 5667"
echo "Range  : 6000-19999"
echo "Cloud  : $RCLONE_REMOTE_DEFAULT"
echo "==============================="
echo "1. Tambah User"
echo "2. Hapus User"
echo "3. List User"
echo "4. Install rclone"
echo "5. Backup ke Cloud"
echo "6. Restore dari Cloud"
echo "0. Keluar"
echo "==============================="

read -p "Pilih: " menu

case $menu in
1) add_user;;
2) remove_user;;
3) list_users; read;;
4) install_rclone;;
5) backup_cloud;;
6) restore_cloud;;
0) exit;;
esac

done