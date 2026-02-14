#!/bin/bash

# ==============================
# ZIVPN - PANEL USER UDP
# ==============================

CONFIG_FILE="/etc/zivpn/config.json"
USER_DB="/etc/zivpn/users.db"
CONF_FILE="/etc/zivpn.conf"
BACKUP_FILE="/etc/zivpn/config.json.bak"

BACKUP_DIR="/root/backup-zivpn"

RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
RESET="\033[0m"

clear

# cek jq
command -v jq >/dev/null 2>&1 || {
  echo -e "${RED}jq belum terinstall. Jalankan: apt install jq -y${RESET}"
  exit 1
}

# buat file jika belum ada
mkdir -p /etc/zivpn
[ ! -f "$CONFIG_FILE" ] && echo '{"listen":":5667","cert":"/etc/zivpn/zivpn.crt","key":"/etc/zivpn/zivpn.key","obfs":"zivpn","auth":{"mode":"passwords","config":["zivpn"]}}' > "$CONFIG_FILE"
[ ! -f "$USER_DB" ] && touch "$USER_DB"
[ ! -f "$CONF_FILE" ] && echo 'AUTOCLEAN=OFF' > "$CONF_FILE"

source "$CONF_FILE"

# ==============================
# BACKUP DATA ZIVPN
# ==============================
backup_zivpn() {
  mkdir -p "$BACKUP_DIR"
  DATE=$(date +%Y-%m-%d_%H-%M-%S)
  FILE="$BACKUP_DIR/zivpn-$DATE.tar.gz"

  tar -czf "$FILE" \
    /etc/zivpn/config.json \
    /etc/zivpn/users.db \
    /etc/zivpn/zivpn.crt \
    /etc/zivpn/zivpn.key \
    /etc/zivpn.conf 2>/dev/null

  echo -e "${GREEN}Backup berhasil dibuat:${RESET}"
  echo "$FILE"
  read -p "Tekan Enter..."
}

# ==============================
# RESTORE DATA ZIVPN
# ==============================
restore_zivpn() {
  echo -e "${YELLOW}Masukkan lokasi file backup${RESET}"
  echo "Contoh: $BACKUP_DIR/zivpn-2026-02-14_12-10-10.tar.gz"
  read -p "File: " file

  [ ! -f "$file" ] && echo -e "${RED}File tidak ditemukan${RESET}" && sleep 2 && return

  systemctl stop zivpn.service 2>/dev/null

  tar -xzf "$file" -C /

  systemctl restart zivpn.service 2>/dev/null

  echo -e "${GREEN}Restore selesai. Semua akun kembali.${RESET}"
  read -p "Tekan Enter..."
}

# ==============================
# TAMBAH USER
# ==============================
add_user() {

echo -e "${CYAN}Buat akun baru (0 untuk batal)${RESET}"

while true; do
  read -p "Password : " pass

  [[ "$pass" == "0" ]] && return

  [[ -z "$pass" ]] && echo -e "${RED}Password tidak boleh kosong${RESET}" && continue

  if jq -e --arg pw "$pass" '.auth.config | index($pw)' "$CONFIG_FILE" > /dev/null; then
    echo -e "${RED}Password sudah ada${RESET}"
    continue
  fi
  break
done

while true; do
  read -p "Masa aktif (hari): " days
  [[ "$days" == "0" ]] && return

  [[ ! "$days" =~ ^[0-9]+$ ]] && echo -e "${RED}Masukkan angka yang valid${RESET}" && continue
  [[ "$days" -le 0 ]] && echo -e "${RED}Hari harus lebih dari 0${RESET}" && continue
  break
done

exp_date=$(date -d "+$days days" +%Y-%m-%d)

cp "$CONFIG_FILE" "$BACKUP_FILE"
jq --arg pw "$pass" '.auth.config += [$pw]' "$CONFIG_FILE" > temp && mv temp "$CONFIG_FILE"
echo "$pass | $exp_date" >> "$USER_DB"

systemctl restart zivpn.service 2>/dev/null

echo -e "${GREEN}User berhasil dibuat. Expired: $exp_date${RESET}"
read -p "Tekan Enter..."
}

# ==============================
# HAPUS USER
# ==============================
remove_user() {

list_users

read -p "ID user (0 batal): " id
[[ "$id" == "0" ]] && return
[[ ! "$id" =~ ^[0-9]+$ ]] && echo -e "${RED}ID harus angka${RESET}" && sleep 2 && return

sel_pass=$(sed -n "${id}p" "$USER_DB" | cut -d'|' -f1 | xargs)

[[ -z "$sel_pass" ]] && echo -e "${RED}ID tidak valid${RESET}" && sleep 2 && return

cp "$CONFIG_FILE" "$BACKUP_FILE"
jq --arg pw "$sel_pass" '.auth.config -= [$pw]' "$CONFIG_FILE" > temp && mv temp "$CONFIG_FILE"
sed -i "/^$sel_pass[[:space:]]*|/d" "$USER_DB"

systemctl restart zivpn.service 2>/dev/null

echo -e "${GREEN}User dihapus${RESET}"
read -p "Tekan Enter..."
}

# ==============================
# PERPANJANG USER
# ==============================
renew_user() {

list_users

read -p "ID user (0 batal): " id
[[ "$id" == "0" ]] && return
[[ ! "$id" =~ ^[0-9]+$ ]] && echo -e "${RED}ID harus angka${RESET}" && sleep 2 && return

sel_pass=$(sed -n "${id}p" "$USER_DB" | cut -d'|' -f1 | xargs)

[[ -z "$sel_pass" ]] && echo -e "${RED}ID tidak valid${RESET}" && sleep 2 && return

read -p "Tambah hari: " days
[[ ! "$days" =~ ^[0-9]+$ ]] && echo -e "${RED}Input salah${RESET}" && sleep 2 && return
[[ "$days" -le 0 ]] && echo -e "${RED}Hari harus lebih dari 0${RESET}" && sleep 2 && return

old_exp=$(sed -n "/^$sel_pass[[:space:]]*|/p" "$USER_DB" | cut -d'|' -f2 | xargs)
new_exp=$(date -d "$old_exp +$days days" +%Y-%m-%d)

sed -i "s/^$sel_pass[[:space:]]*|.*/$sel_pass | $new_exp/" "$USER_DB"

systemctl restart zivpn.service 2>/dev/null

echo -e "${GREEN}User diperpanjang sampai $new_exp${RESET}"
read -p "Tekan Enter..."
}

# ==============================
# LIST USER
# ==============================
list_users() {

echo -e "\n${CYAN}DAFTAR USER${RESET}"
printf "%-4s %-20s %-12s %-10s\n" "ID" "PASSWORD" "EXPIRED" "STATUS"

i=1
today=$(date +%Y-%m-%d)

while IFS='|' read -r pass exp; do
  pass=$(echo "$pass" | xargs)
  exp=$(echo "$exp" | xargs)

  [[ -z "$pass" ]] && continue

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

# ==============================
# CLEAN USER EXPIRED
# ==============================
clean_expired_users() {

today=$(date +%Y-%m-%d)
cp "$CONFIG_FILE" "$BACKUP_FILE"

# pakai file sementara supaya tidak merusak while read (karena sed mengubah file saat dibaca)
tmp_db=$(mktemp)
cp "$USER_DB" "$tmp_db"

while IFS='|' read -r pass exp; do
  pass=$(echo "$pass" | xargs)
  exp=$(echo "$exp" | xargs)
  [[ -z "$pass" ]] && continue

  if [[ "$exp" < "$today" ]]; then
    jq --arg pw "$pass" '.auth.config -= [$pw]' "$CONFIG_FILE" > temp && mv temp "$CONFIG_FILE"
    sed -i "/^$pass[[:space:]]*|/d" "$USER_DB"
  fi
done < "$tmp_db"

rm -f "$tmp_db"
systemctl restart zivpn.service 2>/dev/null
}

toggle_autoclean() {
  if [[ "$AUTOCLEAN" == "ON" ]]; then
    echo "AUTOCLEAN=OFF" > "$CONF_FILE"
    AUTOCLEAN=OFF
  else
    echo "AUTOCLEAN=ON" > "$CONF_FILE"
    AUTOCLEAN=ON
  fi
}

# ==============================
# SERVICE CONTROL
# ==============================
start_service(){ systemctl start zivpn.service 2>/dev/null; }
stop_service(){ systemctl stop zivpn.service 2>/dev/null; }
restart_service(){ systemctl restart zivpn.service 2>/dev/null; }

# ==============================
# MENU
# ==============================
while true; do

clear
[[ "$AUTOCLEAN" == "ON" ]] && clean_expired_users > /dev/null

IP=$(curl -s ifconfig.me)
OS=$(grep -oP '^PRETTY_NAME="\K[^"]+' /etc/os-release)
ARCH=$(uname -m)

echo -e "${CYAN}=========================================${RESET}"
echo -e "           PANEL ZIVPN UDP"
echo -e "${CYAN}=========================================${RESET}"
echo "IP VPS     : $IP"
echo "OS         : $OS"
echo "Arsitektur : $ARCH"
echo "Port       : 5667"
echo "Range UDP  : 6000-19999"
echo "Folder Backup : $BACKUP_DIR"
echo -e "${CYAN}=========================================${RESET}"
echo "1. Tambah User"
echo "2. Hapus User"
echo "3. Perpanjang User"
echo "4. List User"
echo "5. Start Service"
echo "6. Restart Service"
echo "7. Stop Service"
echo "8. Auto Hapus User Expired [$AUTOCLEAN]"
echo "9. Backup User"
echo "10. Restore User"
echo "0. Keluar"
echo -e "${CYAN}=========================================${RESET}"

read -p "Pilih menu: " opc

case $opc in
1) add_user;;
2) remove_user;;
3) renew_user;;
4) list_users; read -p "Enter...";;
5) start_service;;
6) restart_service;;
7) stop_service;;
8) toggle_autoclean;;
9) backup_zivpn;;
10) restore_zivpn;;
0) exit;;
*) echo "Pilihan salah"; sleep 1;;
esac

done