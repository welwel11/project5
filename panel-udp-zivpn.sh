#!/bin/bash

# ==============================
# ZIVPN - PANEL USER UDP (RCLONE ZIP BACKUP + AUTOCLEAN TOGGLE)
# ==============================

CONFIG_FILE="/etc/zivpn/config.json"
USER_DB="/etc/zivpn/users.db"
CONF_FILE="/etc/zivpn.conf"

RCLONE_CONF="/root/.config/rclone/rclone.conf"

# Default (akan di-override otomatis jika ada remote lain)
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
[ -z "$AUTOCLEAN" ] && AUTOCLEAN="OFF"

# ==============================
# HELPERS
# ==============================
pause(){ read -p "Enter..."; }

# Fix rclone.conf yang pakai ":" (YAML-like) jadi " = " (INI)
fix_rclone_conf_format() {
  [ ! -f "$RCLONE_CONF" ] && return 1
  sed -i -E \
    -e 's/^[[:space:]]*(type|scope|token|client_id|client_secret|service_account_file|team_drive|root_folder_id)[[:space:]]*:[[:space:]]*/\1 = /' \
    "$RCLONE_CONF" 2>/dev/null || true
  return 0
}

# Auto-detect remote dari rclone.conf (prioritas: dr -> gdrive -> remote pertama)
detect_rclone_remote() {
  local remotes first
  remotes=$(rclone listremotes 2>/dev/null | tr -d '\r')

  if echo "$remotes" | grep -q "^dr:$"; then
    RCLONE_REMOTE_DEFAULT="dr:zivpn-backup"
    return 0
  fi

  if echo "$remotes" | grep -q "^gdrive:$"; then
    RCLONE_REMOTE_DEFAULT="gdrive:zivpn-backup"
    return 0
  fi

  first=$(echo "$remotes" | head -n1)
  if [ -n "$first" ]; then
    RCLONE_REMOTE_DEFAULT="${first}zivpn-backup"
    return 0
  fi

  return 1
}

ensure_remote_folder() {
  rclone mkdir "$RCLONE_REMOTE_DEFAULT" >/dev/null 2>&1 || true
}

check_rclone() {
  if ! command -v rclone >/dev/null 2>&1; then
    echo -e "${RED}rclone belum terinstall!${RESET}"
    echo -e "${YELLOW}Install:${RESET} apt update -y && apt install -y rclone zip"
    pause
    return 1
  fi

  if [ ! -f "$RCLONE_CONF" ]; then
    echo -e "${RED}rclone.conf tidak ditemukan!${RESET}"
    echo -e "${YELLOW}Buat dulu dengan:${RESET} rclone config"
    pause
    return 1
  fi

  # test baca config / remote
  if ! rclone listremotes >/dev/null 2>&1; then
    if rclone listremotes 2>&1 | grep -qi "didn't find section"; then
      echo -e "${YELLOW}Format rclone.conf terdeteksi salah (pakai ':'). Memperbaiki...${RESET}"
      fix_rclone_conf_format
    fi
  fi

  if ! rclone listremotes >/dev/null 2>&1; then
    echo -e "${RED}rclone masih error membaca config.${RESET}"
    echo -e "${YELLOW}Cek file:${RESET} $RCLONE_CONF"
    pause
    return 1
  fi

  if ! detect_rclone_remote; then
    echo -e "${RED}Tidak ada remote rclone yang terdeteksi.${RESET}"
    echo -e "${YELLOW}Jalankan:${RESET} rclone config"
    pause
    return 1
  fi

  ensure_remote_folder
  return 0
}

# ==============================
# AUTO CLEAN EXPIRED (hapus dari config + db)
# ==============================
clean_expired_users() {
  [ "$AUTOCLEAN" != "ON" ] && return

  [ ! -f "$USER_DB" ] && return
  [ ! -f "$CONFIG_FILE" ] && return

  local today tmpdb pass exp changed=0
  today=$(date +%Y-%m-%d)
  tmpdb="/tmp/zivpn_users.$$"
  > "$tmpdb"

  while IFS='|' read -r pass exp; do
    pass=$(echo "$pass" | xargs)
    exp=$(echo "$exp" | xargs)
    [ -z "$pass" ] && continue

    if [[ "$exp" < "$today" ]]; then
      # hapus password dari config.json
      jq --arg pw "$pass" '.auth.config -= [$pw]' "$CONFIG_FILE" > /tmp/zivpn.tmp && mv /tmp/zivpn.tmp "$CONFIG_FILE"
      changed=1
      continue
    fi

    echo "$pass | $exp" >> "$tmpdb"
  done < "$USER_DB"

  mv "$tmpdb" "$USER_DB"
  if [ "$changed" = "1" ]; then
    systemctl restart zivpn.service 2>/dev/null || true
  fi
}

toggle_autoclean() {
  # pastikan file ada + format konsisten
  grep -q "^AUTOCLEAN=" "$CONF_FILE" 2>/dev/null || echo "AUTOCLEAN=OFF" >> "$CONF_FILE"

  if grep -q "^AUTOCLEAN=ON" "$CONF_FILE"; then
    sed -i 's/^AUTOCLEAN=ON/AUTOCLEAN=OFF/' "$CONF_FILE"
    AUTOCLEAN="OFF"
    echo -e "${YELLOW}Auto hapus akun expired DIMATIKAN${RESET}"
  else
    sed -i 's/^AUTOCLEAN=OFF/AUTOCLEAN=ON/' "$CONF_FILE"
    AUTOCLEAN="ON"
    echo -e "${GREEN}Auto hapus akun expired DIAKTIFKAN${RESET}"
  fi

  source "$CONF_FILE" 2>/dev/null || true
  pause
}

# ==============================
# BACKUP KE CLOUD (ZIP) - ZIVPN SAJA
# ==============================
backup_cloud() {
  clean_expired_users
  check_rclone || return

  local TS FILE
  TS="$(date +%Y%m%d-%H%M%S)"
  FILE="/tmp/zivpn-${TS}.zip"

  (cd / && zip -q -r "$FILE" \
    etc/zivpn/config.json \
    etc/zivpn/users.db \
    etc/zivpn/zivpn.crt \
    etc/zivpn/zivpn.key \
    etc/zivpn.conf 2>/dev/null)

  if [ ! -s "$FILE" ]; then
    echo -e "${RED}Gagal membuat backup ZIP (file kosong).${RESET}"
    pause
    return
  fi

  echo -e "${CYAN}Upload ZIP ke cloud: ${YELLOW}${RCLONE_REMOTE_DEFAULT}${RESET}"
  if rclone copy "$FILE" "$RCLONE_REMOTE_DEFAULT" --progress; then
    rm -f "$FILE"
    echo -e "${GREEN}Backup selesai: zivpn-${TS}.zip${RESET}"
  else
    echo -e "${RED}Upload gagal. File lokal disimpan: $FILE${RESET}"
  fi

  pause
}

# ==============================
# RESTORE DARI CLOUD (ZIP) - CLEAN MODE (PASTE FILENAME)
# ==============================
restore_cloud() {
  check_rclone || return

  mkdir -p /tmp/zrestore

  echo
  echo -e "${CYAN}RESTORE BACKUP ZIVPN${RESET}"
  echo -e "${YELLOW}Paste nama file .zip yang mau direstore${RESET}"
  echo -e "${YELLOW}Contoh: zivpn-20260214-093905.zip${RESET}"
  echo

  read -p "Nama file backup: " fname
  [ -z "$fname" ] && rm -rf /tmp/zrestore && return

  echo -e "${CYAN}Download backup...${RESET}"
  if ! rclone copyto "$RCLONE_REMOTE_DEFAULT/$fname" "/tmp/zrestore/$fname" --progress; then
    echo -e "${RED}Download gagal. Pastikan nama file benar.${RESET}"
    rm -rf /tmp/zrestore
    pause
    return
  fi

  if [ ! -s "/tmp/zrestore/$fname" ]; then
    echo -e "${RED}File hasil download kosong / tidak ada.${RESET}"
    rm -rf /tmp/zrestore
    pause
    return
  fi

  local BAK="/tmp/zivpn-before-restore-$(date +%Y%m%d-%H%M%S).zip"
  (cd / && zip -q -r "$BAK" etc/zivpn etc/zivpn.conf 2>/dev/null) || true
  echo -e "${YELLOW}Backup sebelum restore disimpan: $BAK${RESET}"

  systemctl stop zivpn.service 2>/dev/null || true

  echo -e "${CYAN}Extract ke sistem...${RESET}"
  if ! unzip -o "/tmp/zrestore/$fname" -d / >/dev/null; then
    echo -e "${RED}Extract gagal. Kamu bisa rollback pakai: $BAK${RESET}"
    systemctl start zivpn.service 2>/dev/null || true
    rm -rf /tmp/zrestore
    pause
    return
  fi

  source "$CONF_FILE" 2>/dev/null || true
  [ -z "$AUTOCLEAN" ] && AUTOCLEAN="OFF"

  systemctl daemon-reload 2>/dev/null || true
  systemctl restart zivpn.service 2>/dev/null || true

  rm -rf /tmp/zrestore
  echo -e "${GREEN}Restore selesai${RESET}"
  pause
}

# ==============================
# USER MANAGEMENT
# ==============================
add_user() {
  clean_expired_users
  echo -e "${CYAN}Buat akun baru${RESET}"

  read -p "Password : " pass
  [[ -z "$pass" ]] && echo "Kosong!" && pause && return

  if jq -e --arg pw "$pass" '.auth.config | index($pw)' "$CONFIG_FILE" >/dev/null 2>&1; then
    echo -e "${RED}Password sudah ada${RESET}"
    pause
    return
  fi

  read -p "Masa aktif (hari): " days
  [[ ! "$days" =~ ^[0-9]+$ ]] && echo -e "${RED}Hari harus angka${RESET}" && pause && return

  local exp_date
  exp_date=$(date -d "+$days days" +%Y-%m-%d)

  jq --arg pw "$pass" '.auth.config += [$pw]' "$CONFIG_FILE" > /tmp/zivpn.tmp && mv /tmp/zivpn.tmp "$CONFIG_FILE"
  echo "$pass | $exp_date" >> "$USER_DB"

  systemctl restart zivpn.service 2>/dev/null || true
  echo -e "${GREEN}User aktif sampai $exp_date${RESET}"
  pause
}

list_users() {
  clean_expired_users
  echo
  printf "%-4s %-20s %-12s %-10s\n" "ID" "PASSWORD" "EXPIRED" "STATUS"

  local i=1 today
  today=$(date +%Y-%m-%d)

  while IFS='|' read -r pass exp; do
    pass=$(echo "$pass" | xargs)
    exp=$(echo "$exp" | xargs)
    [ -z "$pass" ] && continue

    local status="AKTIF"
    [[ "$exp" < "$today" ]] && status="EXPIRED"

    printf "%-4s %-20s %-12s %-10s\n" "$i" "$pass" "$exp" "$status"
    ((i++))
  done < "$USER_DB"
  echo
}

remove_user() {
  clean_expired_users
  list_users
  read -p "ID: " id
  [[ ! "$id" =~ ^[0-9]+$ ]] && echo -e "${RED}ID harus angka${RESET}" && sleep 1 && return

  local sel_pass
  sel_pass=$(sed -n "${id}p" "$USER_DB" | cut -d'|' -f1 | xargs)
  [ -z "$sel_pass" ] && echo -e "${RED}ID tidak valid${RESET}" && sleep 1 && return

  jq --arg pw "$sel_pass" '.auth.config -= [$pw]' "$CONFIG_FILE" > /tmp/zivpn.tmp && mv /tmp/zivpn.tmp "$CONFIG_FILE"
  sed -i "/^$sel_pass[[:space:]]*|/d" "$USER_DB"

  systemctl restart zivpn.service 2>/dev/null || true
  echo -e "${GREEN}User dihapus${RESET}"
  sleep 1
}

# Jalankan sekali saat start menu (kalau AUTOCLEAN=ON)
clean_expired_users

# ==============================
# MENU
# ==============================
while true; do
  clear
  IP=$(curl -s ifconfig.me 2>/dev/null)

  echo "==============================="
  echo "        PANEL ZIVPN UDP"
  echo "==============================="
  echo "IP VPS     : ${IP:-N/A}"
  echo "Port       : 5667"
  echo "Range      : 6000-19999"
  echo "AutoClean  : $AUTOCLEAN"
  echo "==============================="
  echo "1. Tambah User"
  echo "2. Hapus User"
  echo "3. List User"
  echo "4. Backup"
  echo "5. Restore"
  echo "6. Toggle Auto Hapus Expired"
  echo "0. Keluar"
  echo "==============================="

  read -p "Pilih: " menu

  case $menu in
    1) add_user;;
    2) remove_user;;
    3) list_users; pause;;
    4) backup_cloud;;
    5) restore_cloud;;
    6) toggle_autoclean;;
    0) exit;;
    *) echo "Pilihan salah"; sleep 1;;
  esac
done