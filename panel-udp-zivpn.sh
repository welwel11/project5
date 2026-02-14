#!/bin/bash

# ==============================
# ZIVPN - PANEL USER UDP (RCLONE ZIP BACKUP + AUTO FIX CONF)
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

# ==============================
# HELPERS
# ==============================
pause(){ read -p "Enter..."; }

# Fix rclone.conf yang pakai ":" (YAML-like) jadi " = " (INI)
fix_rclone_conf_format() {
  [ ! -f "$RCLONE_CONF" ] && return 1

  # hanya ubah key yang umum dipakai rclone, biar aman
  # contoh: type: drive  -> type = drive
  #         scope: drive -> scope = drive
  #         token: {...} -> token = {...}
  sed -i -E \
    -e 's/^[[:space:]]*(type|scope|token|client_id|client_secret|service_account_file|team_drive|root_folder_id)[[:space:]]*:[[:space:]]*/\1 = /' \
    "$RCLONE_CONF" 2>/dev/null || true

  return 0
}

# Auto-detect remote dari rclone.conf (prioritas: dr -> gdrive -> remote pertama)
detect_rclone_remote() {
  local remotes
  remotes=$(rclone listremotes 2>/dev/null | tr -d '\r')

  if echo "$remotes" | grep -q "^dr:$"; then
    RCLONE_REMOTE_DEFAULT="dr:zivpn-backup"
    return 0
  fi

  if echo "$remotes" | grep -q "^gdrive:$"; then
    RCLONE_REMOTE_DEFAULT="gdrive:zivpn-backup"
    return 0
  fi

  # fallback: pakai remote pertama jika ada
  local first
  first=$(echo "$remotes" | head -n1)
  if [ -n "$first" ]; then
    RCLONE_REMOTE_DEFAULT="${first}zivpn-backup"
    return 0
  fi

  return 1
}

ensure_remote_folder() {
  # bikin folder di root remote jika belum ada
  # rclone mkdir aman walau folder sudah ada
  rclone mkdir "$RCLONE_REMOTE_DEFAULT" >/dev/null 2>&1 || true
}

# ==============================
# INSTALL RCLONE + ZIP
# ==============================
install_rclone() {
  apt update -y >/dev/null 2>&1
  apt install -y rclone zip >/dev/null 2>&1
  mkdir -p /root/.config/rclone
  echo -e "${GREEN}rclone + zip berhasil diinstall${RESET}"
  echo -e "${YELLOW}Sekarang jalankan perintah: rclone config${RESET}"
  pause
}

check_rclone() {
  if ! command -v rclone >/dev/null 2>&1; then
    echo -e "${RED}rclone belum terinstall!${RESET}"
    echo "Pilih menu: Install rclone + zip"
    pause
    return 1
  fi

  if [ ! -f "$RCLONE_CONF" ]; then
    echo -e "${RED}rclone.conf tidak ditemukan!${RESET}"
    echo "Buat dulu dengan: rclone config"
    pause
    return 1
  fi

  # test baca config / remote
  if ! rclone listremotes >/dev/null 2>&1; then
    # kalau error karena format ":", coba auto-fix sekali
    if rclone listremotes 2>&1 | grep -qi "didn't find section"; then
      echo -e "${YELLOW}Format rclone.conf terdeteksi salah (pakai ':'). Memperbaiki...${RESET}"
      fix_rclone_conf_format
    fi
  fi

  # test ulang
  if ! rclone listremotes >/dev/null 2>&1; then
    echo -e "${RED}rclone masih error membaca config.${RESET}"
    echo -e "${YELLOW}Cek file:${RESET} $RCLONE_CONF"
    pause
    return 1
  fi

  # auto-detect remote (dr:, gdrive:, dsb)
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
# RESTORE DARI CLOUD (ZIP)
# ==============================
restore_cloud() {
  check_rclone || return

  mkdir -p /tmp/zrestore

  echo -e "${CYAN}Daftar backup (.zip) di: ${YELLOW}${RCLONE_REMOTE_DEFAULT}${RESET}"
  rclone lsf "$RCLONE_REMOTE_DEFAULT" 2>/dev/null | grep -E '\.zip$' | nl
  echo

  read -p "Nama file backup (contoh: zivpn-YYYYmmdd-HHMMSS.zip): " fname
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
    pause
    return
  fi

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
  echo -e "${CYAN}Buat akun baru${RESET}"

  read -p "Password : " pass
  [[ -z "$pass" ]] && echo "Kosong!" && pause && return

  # cegah duplikat password
  if jq -e --arg pw "$pass" '.auth.config | index($pw)' "$CONFIG_FILE" >/dev/null 2>&1; then
    echo -e "${RED}Password sudah ada${RESET}"
    pause
    return
  fi

  read -p "Masa aktif (hari): " days
  [[ ! "$days" =~ ^[0-9]+$ ]] && echo -e "${RED}Hari harus angka${RESET}" && pause && return

  exp_date=$(date -d "+$days days" +%Y-%m-%d)

  jq --arg pw "$pass" '.auth.config += [$pw]' "$CONFIG_FILE" > /tmp/zivpn.tmp && mv /tmp/zivpn.tmp "$CONFIG_FILE"
  echo "$pass | $exp_date" >> "$USER_DB"

  systemctl restart zivpn.service 2>/dev/null || true
  echo -e "${GREEN}User aktif sampai $exp_date${RESET}"
  pause
}

list_users() {
  echo
  printf "%-4s %-20s %-12s %-10s\n" "ID" "PASSWORD" "EXPIRED" "STATUS"

  local i=1
  local today
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
  echo "7. Fix rclone.conf (':' -> '=')"
  echo "0. Keluar"
  echo "==============================="

  read -p "Pilih: " menu

  case $menu in
    1) add_user;;
    2) remove_user;;
    3) list_users; pause;;
    4) install_rclone;;
    5) backup_cloud;;
    6) restore_cloud;;
    7) fix_rclone_conf_format; echo -e "${GREEN}Selesai memperbaiki format rclone.conf${RESET}"; pause;;
    0) exit;;
    *) echo "Pilihan salah"; sleep 1;;
  esac
done