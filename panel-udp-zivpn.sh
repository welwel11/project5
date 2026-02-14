#!/bin/bash

# ==============================
# ZIVPN - PANEL USER UDP (RCLONE ZIP BACKUP)
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

source "$CONF_FILE" 2>/dev/null || true

# ==============================
# INSTALL RCLONE + ZIP
# ==============================
install_rclone() {
  apt update -y >/dev/null 2>&1
  apt install -y rclone zip >/dev/null 2>&1
  mkdir -p /root/.config/rclone
  echo -e "${GREEN}rclone + zip berhasil diinstall${RESET}"
  echo -e "${YELLOW}Sekarang jalankan perintah: rclone config${RESET}"
  read -p "Enter..."
}

check_rclone() {
  if ! command -v rclone >/dev/null 2>&1; then
    echo -e "${RED}rclone belum terinstall!${RESET}"
    echo "Pilih menu: Install rclone"
    read -p "Enter..."
    return 1
  fi

  if [ ! -f "$RCLONE_CONF" ]; then
    echo -e "${RED}rclone belum dikonfigurasi!${RESET}"
    echo "Jalankan: rclone config"
    read -p "Enter..."
    return 1
  fi

  return 0
}

# ==============================
# BACKUP KE CLOUD (ZIP)
# ==============================
backup_cloud() {
  check_rclone || return

  local TS FILE
  TS="$(date +%Y%m%d-%H%M%S)"
  FILE="/tmp/zivpn-${TS}.zip"

  # bikin ZIP dari root supaya path tetap benar saat restore
  (cd / && zip -q -r "$FILE" \
    etc/zivpn/config.json \
    etc/zivpn/users.db \
    etc/zivpn/zivpn.crt \
    etc/zivpn/zivpn.key \
    etc/zivpn.conf 2>/dev/null)

  if [ ! -s "$FILE" ]; then
    echo -e "${RED}Gagal membuat backup ZIP (file kosong).${RESET}"
    read -p "Enter..."
    return
  fi

  echo -e "${CYAN}Upload ZIP ke cloud...${RESET}"
  if rclone copy "$FILE" "$RCLONE_REMOTE_DEFAULT" --progress; then
    rm -f "$FILE"
    echo -e "${GREEN}Backup selesai: zivpn-${TS}.zip${RESET}"
  else
    echo -e "${RED}Upload gagal. File lokal disimpan: $FILE${RESET}"
  fi

  read -p "Enter..."
}

# ==============================
# RESTORE DARI CLOUD (ZIP)
# ==============================
restore_cloud() {
  check_rclone || return

  mkdir -p /tmp/zrestore

  echo -e "${CYAN}Daftar backup (.zip):${RESET}"
  rclone lsf "$RCLONE_REMOTE_DEFAULT" | grep -E '\.zip$' | nl
  echo

  read -p "Nama file backup (contoh: zivpn-YYYYmmdd-HHMMSS.zip): " fname
  [ -z "$fname" ] && rm -rf /tmp/zrestore && return

  echo -e "${CYAN}Download backup...${RESET}"
  if ! rclone copyto "$RCLONE_REMOTE_DEFAULT/$fname" "/tmp/zrestore/$fname" --progress; then
    echo -e "${RED}Download gagal. Pastikan nama file benar.${RESET}"
    rm -rf /tmp/zrestore
    read -p "Enter..."
    return
  fi

  if [ ! -s "/tmp/zrestore/$fname" ]; then
    echo -e "${RED}File hasil download kosong / tidak ada.${RESET}"
    rm -rf /tmp/zrestore
    read -p "Enter..."
    return
  fi

  # backup cepat sebelum restore (rollback)
  local BAK="/tmp/zivpn-before-restore-$(date +%Y%m%d-%H%M%S).zip"
  (cd / && zip -q -r "$BAK" etc/zivpn etc/zivpn.conf 2>/dev/null) || true
  echo -e "${YELLOW}Backup sebelum restore disimpan: $BAK${RESET}"

  systemctl stop zivpn.service 2>/dev/null || true

  echo -e "${CYAN}Extract ke sistem...${RESET}"
  if ! unzip -o "/tmp/zrestore/$fname" -d / >/dev/null; then
    echo -e "${RED}Extract gagal. Kamu bisa rollback pakai: $BAK${RESET}"
    systemctl start zivpn.service 2>/dev/null || true
    rm -rf /tmp/zrestore
    read -p "Enter..."
    return
  fi

  systemctl daemon-reload 2>/dev/null || true
  systemctl restart zivpn.service 2>/dev/null || true

  rm -rf /tmp/zrestore
  echo -e "${GREEN}Restore selesai${RESET}"
  read -p "Enter..."
}

# ==============================
# USER MANAGEMENT
# ==============================
add_user() {
  echo -e "${CYAN}Buat akun baru${RESET}"

  read -p "Password : " pass
  [[ -z "$pass" ]] && echo "Kosong!" && read -p "Enter..." && return

  # cegah duplikat password
  if jq -e --arg pw "$pass" '.auth.config | index($pw)' "$CONFIG_FILE" >/dev/null 2>&1; then
    echo -e "${RED}Password sudah ada${RESET}"
    read -p "Enter..."
    return
  fi

  read -p "Masa aktif (hari): " days
  [[ ! "$days" =~ ^[0-9]+$ ]] && echo -e "${RED}Hari harus angka${RESET}" && read -p "Enter..." && return

  exp_date=$(date -d "+$days days" +%Y-%m-%d)

  jq --arg pw "$pass" '.auth.config += [$pw]' "$CONFIG_FILE" > /tmp/zivpn.tmp && mv /tmp/zivpn.tmp "$CONFIG_FILE"
  echo "$pass | $exp_date" >> "$USER_DB"

  systemctl restart zivpn.service 2>/dev/null || true
  echo -e "${GREEN}User aktif sampai $exp_date${RESET}"
  read -p "Enter..."
}

list_users() {
  echo
  printf "%-4s %-20s %-12s %-10s\n" "ID" "PASSWORD" "EXPIRED" "STATUS"

  i=1
  today=$(date +%Y-%m-%d)

  while IFS='|' read -r pass exp; do
    pass=$(echo "$pass" | xargs)
    exp=$(echo "$exp" | xargs)
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

remove_user() {
  list_users
  read -p "ID: " id
  [[ ! "$id" =~ ^[0-9]+$ ]] && echo -e "${RED}ID harus angka${RESET}" && sleep 1 && return

  sel_pass=$(sed -n "${id}p" "$USER_DB" | cut -d'|' -f1 | xargs)
  [ -z "$sel_pass" ] && echo -e "${RED}ID tidak valid${RESET}" && sleep 1 && return

  jq --arg pw "$sel_pass" '.auth.config -= [$pw]' "$CONFIG_FILE" > /tmp/zivpn.tmp && mv /tmp/zivpn.tmp "$CONFIG_FILE"
  sed -i "/^$sel_pass[[:space:]]*|/d" "$USER_DB"

  systemctl restart zivpn.service 2>/dev/null || true
  echo -e "${GREEN}User dihapus${RESET}"
  sleep 1
}

# ==============================
# MENU
# ==============================
while true; do
  clear
  IP=$(curl -s ifconfig.me 2>/dev/null)

  echo "==============================="
  echo "        PANEL ZIVPN UDP"
  echo "==============================="
  echo "IP VPS : ${IP:-N/A}"
  echo "Port   : 5667"
  echo "Range  : 6000-19999"
  echo "Cloud  : $RCLONE_REMOTE_DEFAULT"
  echo "==============================="
  echo "1. Tambah User"
  echo "2. Hapus User"
  echo "3. List User"
  echo "4. Install rclone + zip"
  echo "5. Backup ke Cloud (ZIP)"
  echo "6. Restore dari Cloud (ZIP)"
  echo "0. Keluar"
  echo "==============================="

  read -p "Pilih: " menu

  case $menu in
    1) add_user;;
    2) remove_user;;
    3) list_users; read -p "Enter...";;
    4) install_rclone;;
    5) backup_cloud;;
    6) restore_cloud;;
    0) exit;;
    *) echo "Pilihan salah"; sleep 1;;
  esac
done