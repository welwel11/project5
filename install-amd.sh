#!/bin/bash

# Warna
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
RED="\033[1;31m"
MAGENTA="\033[1;35m"
RESET="\033[0m"

# =========================
# KONFIG BACKUP
# =========================
BACKUP_DIR="/root/zivpn-backup"
RCLONE_CONF="/root/.config/rclone/rclone.conf"
RCLONE_REMOTE_DEFAULT="gdrive:zivpn-backup"

# =========================
# KONFIG AUTO MENU
# =========================
AUTO_MENU_AFTER_REBOOT=1     # 1=aktif, 0=nonaktif
AUTO_REBOOT_AFTER_INSTALL=1  # 1=reboot otomatis, 0=tidak

print_section() {
  local title="$1"
  echo -e "${MAGENTA}============================================================${RESET}"
  echo -e "${MAGENTA}${title}${RESET}"
  echo -e "${MAGENTA}============================================================${RESET}"
}

run_with_spinner() {
  local msg="$1"
  local cmd="$2"

  echo -ne "${CYAN}${msg}...${RESET}"
  bash -c "$cmd" &>/tmp/zivpn_spinner.log &
  local pid=$!

  local delay=0.1
  local spinstr='|/-\'
  while kill -0 $pid 2>/dev/null; do
    local temp=${spinstr#?}
    printf " [%c]  " "$spinstr"
    local spinstr=$temp${spinstr%"$temp"}
    sleep $delay
    printf "\b\b\b\b\b\b"
  done
  wait $pid
  local exit_code=$?

  if [ $exit_code -eq 0 ]; then
    echo -e " ${GREEN}OK${RESET}"
  else
    echo -e " ${RED}GAGAL${RESET}"
    echo -e "${RED}Error saat menjalankan:${RESET} ${YELLOW}$msg${RESET}"
    echo -e "${RED}Detail:${RESET}"
    cat /tmp/zivpn_spinner.log
    exit 1
  fi
  rm -f /tmp/zivpn_spinner.log
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Jalankan sebagai root (sudo -i)${RESET}"
    exit 1
  fi
}

# =========================
# AUTO RUN menu-zivpn SETIAP LOGIN ROOT
# =========================
setup_autorun_menu_always() {
  print_section "Menyiapkan auto buka menu setiap login root"

  local BASHRC="/root/.bashrc"
  [ -f "$BASHRC" ] && cp -a "$BASHRC" "/root/.bashrc.bak" 2>/dev/null || true

  # bersihkan blok lama agar tidak dobel
  sed -i '/# ===== AUTO RUN MENU ZIVPN (ALWAYS) =====/,/# =======================================/d' "$BASHRC" 2>/dev/null || true
  sed -i '/# ===== AUTO RUN MENU ZIVPN (ONCE) =====/,/# =====================================/d' "$BASHRC" 2>/dev/null || true

  cat <<'EOF' >> /root/.bashrc

# ===== AUTO RUN MENU ZIVPN (ALWAYS) =====
# Jalan setiap login root pada shell interaktif (SSH/console)
if [ -n "$PS1" ]; then
  if command -v menu-zivpn >/dev/null 2>&1; then
    clear
    echo "Memuat Panel ZIVPN..."
    sleep 1
    menu-zivpn
  fi
fi
# =======================================

EOF

  echo -e "${GREEN}Berhasil. Setiap login root, menu-zivpn akan terbuka otomatis.${RESET}"
}

disable_autorun_menu() {
  print_section "Mematikan auto menu-zivpn"
  sed -i '/# ===== AUTO RUN MENU ZIVPN (ALWAYS) =====/,/# =======================================/d' /root/.bashrc 2>/dev/null || true
  sed -i '/# ===== AUTO RUN MENU ZIVPN (ONCE) =====/,/# =====================================/d' /root/.bashrc 2>/dev/null || true
  echo -e "${GREEN}Auto menu-zivpn dimatikan.${RESET}"
}

# =========================
# FIX IPTABLES PERSISTENT (ZIVPN) - DIPERBAIKI
# =========================
ensure_zivpn_iptables_persist() {
  print_section "Menerapkan iptables untuk ZIVPN (lebih stabil) dan menyimpannya"

  local ZIVPN_PORT="5667"
  local PORT_FROM="6000"
  local PORT_TO="19999"

  echo -e "${CYAN}Mendeteksi interface default...${RESET}"
  local iface
  iface=$(ip -4 route ls | awk '/default/ {print $5; exit}')
  if [[ -z "$iface" ]]; then
    echo -e "${RED}Gagal mendeteksi interface default. Dibatalkan.${RESET}"
    return 1
  fi
  echo -e "${CYAN}Interface terdeteksi: ${YELLOW}$iface${RESET}"

  echo -e "${CYAN}Membersihkan rule lama (DNAT/REDIRECT) agar tidak dobel...${RESET}"

  # Hapus rule DNAT lama (kalau ada) - dengan / tanpa -i iface
  while iptables -t nat -C PREROUTING -p udp --dport ${PORT_FROM}:${PORT_TO} -j DNAT --to-destination :${ZIVPN_PORT} 2>/dev/null; do
    iptables -t nat -D PREROUTING -p udp --dport ${PORT_FROM}:${PORT_TO} -j DNAT --to-destination :${ZIVPN_PORT} 2>/dev/null || break
  done
  while iptables -t nat -C PREROUTING -i "$iface" -p udp --dport ${PORT_FROM}:${PORT_TO} -j DNAT --to-destination :${ZIVPN_PORT} 2>/dev/null; do
    iptables -t nat -D PREROUTING -i "$iface" -p udp --dport ${PORT_FROM}:${PORT_TO} -j DNAT --to-destination :${ZIVPN_PORT} 2>/dev/null || break
  done

  # Hapus rule REDIRECT lama (kalau ada) - dengan / tanpa -i iface
  while iptables -t nat -C PREROUTING -p udp --dport ${PORT_FROM}:${PORT_TO} -j REDIRECT --to-ports ${ZIVPN_PORT} 2>/dev/null; do
    iptables -t nat -D PREROUTING -p udp --dport ${PORT_FROM}:${PORT_TO} -j REDIRECT --to-ports ${ZIVPN_PORT} 2>/dev/null || break
  done
  while iptables -t nat -C PREROUTING -i "$iface" -p udp --dport ${PORT_FROM}:${PORT_TO} -j REDIRECT --to-ports ${ZIVPN_PORT} 2>/dev/null; do
    iptables -t nat -D PREROUTING -i "$iface" -p udp --dport ${PORT_FROM}:${PORT_TO} -j REDIRECT --to-ports ${ZIVPN_PORT} 2>/dev/null || break
  done

  echo -e "${CYAN}Memasang rule yang benar (REDIRECT -> UDP ${ZIVPN_PORT})...${RESET}"
  iptables -t nat -A PREROUTING -p udp --dport ${PORT_FROM}:${PORT_TO} -j REDIRECT --to-ports ${ZIVPN_PORT}

  echo -e "${CYAN}Memastikan INPUT mengizinkan UDP ${ZIVPN_PORT}...${RESET}"
  if iptables -C INPUT -p udp --dport ${ZIVPN_PORT} -j ACCEPT 2>/dev/null; then
    echo -e "${YELLOW}Rule INPUT sudah ada. Lewati.${RESET}"
  else
    iptables -A INPUT -p udp --dport ${ZIVPN_PORT} -j ACCEPT
  fi

  if command -v ufw >/dev/null 2>&1; then
    echo -e "${CYAN}Mengatur UFW...${RESET}"
    ufw allow ${PORT_FROM}:${PORT_TO}/udp >/dev/null 2>&1 || true
    ufw allow ${ZIVPN_PORT}/udp >/dev/null 2>&1 || true
  fi

  if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
    echo -e "${CYAN}Menginstall iptables-persistent...${RESET}"
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
    run_with_spinner "Install iptables-persistent" "apt-get update -y && apt-get install -y iptables-persistent"
  fi

  echo -e "${CYAN}Menyimpan rule untuk reboot...${RESET}"
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true

  echo -e "${GREEN}iptables ZIVPN sudah diterapkan (REDIRECT) dan disimpan.${RESET}"
}

# =========================
# UNINSTALL / REINSTALL (ZIVPN)
# =========================
zivpn_uninstall() {
  print_section "Menghapus instalasi ZIVPN lama"

  run_with_spinner "Stop service zivpn" "systemctl stop zivpn.service 2>/dev/null || true"
  run_with_spinner "Disable service zivpn" "systemctl disable zivpn.service 2>/dev/null || true"

  run_with_spinner "Hapus file service" "rm -f /etc/systemd/system/zivpn.service"
  run_with_spinner "Reload systemd" "systemctl daemon-reload"

  run_with_spinner "Hapus binary zivpn" "rm -f /usr/local/bin/zivpn"
  run_with_spinner "Hapus menu-zivpn" "rm -f /usr/local/bin/menu-zivpn"
  run_with_spinner "Hapus folder config /etc/zivpn" "rm -rf /etc/zivpn"

  # Bersihkan rule NAT ZIVPN (DNAT/REDIRECT) + INPUT accept agar tidak nyangkut
  local ZIVPN_PORT="5667"
  local PORT_FROM="6000"
  local PORT_TO="19999"

  while iptables -t nat -C PREROUTING -p udp --dport ${PORT_FROM}:${PORT_TO} -j DNAT --to-destination :${ZIVPN_PORT} 2>/dev/null; do
    iptables -t nat -D PREROUTING -p udp --dport ${PORT_FROM}:${PORT_TO} -j DNAT --to-destination :${ZIVPN_PORT} 2>/dev/null || break
  done
  while iptables -t nat -C PREROUTING -p udp --dport ${PORT_FROM}:${PORT_TO} -j REDIRECT --to-ports ${ZIVPN_PORT} 2>/dev/null; do
    iptables -t nat -D PREROUTING -p udp --dport ${PORT_FROM}:${PORT_TO} -j REDIRECT --to-ports ${ZIVPN_PORT} 2>/dev/null || break
  done
  while iptables -C INPUT -p udp --dport ${ZIVPN_PORT} -j ACCEPT 2>/dev/null; do
    iptables -D INPUT -p udp --dport ${ZIVPN_PORT} -j ACCEPT 2>/dev/null || break
  done

  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true

  echo -e "${GREEN}ZIVPN berhasil dihapus.${RESET}"
}

# =========================
# BACKUP / RESTORE
# =========================
ins_backup_tools() {
  print_section "Memasang tools backup (rclone)"
  run_with_spinner "Install rclone, tar, gzip" "apt-get update -y && apt-get install -y rclone tar gzip"
  mkdir -p "$(dirname "$RCLONE_CONF")" "$BACKUP_DIR"
  echo -e "${GREEN}Tools backup siap.${RESET}"
  echo -e "${YELLOW}Catatan:${RESET} Jalankan: ${CYAN}rclone config${RESET} (sekali saja) untuk set remote."
}

zivpn_make_backup() {
  print_section "Backup ZIVPN UDP (lokal)"
  mkdir -p "$BACKUP_DIR"

  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  local tmp="/tmp/zivpn_backup_$ts"
  local out="$BACKUP_DIR/zivpn-backup-$ts.tar.gz"
  mkdir -p "$tmp/files"

  echo -e "${CYAN}Mengumpulkan file...${RESET}"
  [ -d /etc/zivpn ] && cp -a /etc/zivpn "$tmp/files/" 2>/dev/null || true
  [ -f /etc/systemd/system/zivpn.service ] && cp -a /etc/systemd/system/zivpn.service "$tmp/files/" 2>/dev/null || true
  [ -f /usr/local/bin/zivpn ] && cp -a /usr/local/bin/zivpn "$tmp/files/" 2>/dev/null || true
  [ -f /usr/local/bin/menu-zivpn ] && cp -a /usr/local/bin/menu-zivpn "$tmp/files/" 2>/dev/null || true

  echo -e "${CYAN}Menyimpan rule firewall...${RESET}"
  iptables-save > "$tmp/iptables.rules" 2>/dev/null || true
  ip6tables-save > "$tmp/ip6tables.rules" 2>/dev/null || true
  if command -v ufw >/dev/null 2>&1; then
    ufw status verbose > "$tmp/ufw.status" 2>/dev/null || true
  fi

  echo -e "${CYAN}Menyimpan info sistem...${RESET}"
  {
    echo "DATE=$ts"
    uname -a
    cat /etc/os-release 2>/dev/null || true
    echo "IFACE_DEFAULT=$(ip -4 route ls | awk '/default/ {print $5; exit}')"
  } > "$tmp/system.info" 2>/dev/null || true

  run_with_spinner "Membuat arsip backup" "tar -czf '$out' -C '$tmp' ."
  rm -rf "$tmp"

  echo -e "${GREEN}Backup selesai:${RESET} ${YELLOW}$out${RESET}"
  echo "$out"
}

zivpn_upload_backup_rclone() {
  local file="$1"
  local remote="${2:-$RCLONE_REMOTE_DEFAULT}"

  print_section "Upload backup (rclone)"
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    echo -e "${RED}File backup tidak ditemukan.${RESET}"
    echo -e "${YELLOW}Pakai:${RESET} $0 upload /root/zivpn-backup/zivpn-backup-XXXX.tar.gz [remote:folder]"
    exit 1
  fi

  if [ ! -f "$RCLONE_CONF" ]; then
    echo -e "${RED}rclone.conf belum ada di:${RESET} $RCLONE_CONF"
    echo -e "${YELLOW}Jalankan:${RESET} ${CYAN}rclone config${RESET} untuk buat remote."
    exit 1
  fi

  run_with_spinner "Upload ke $remote" "rclone copy '$file' '$remote' --progress"
  echo -e "${GREEN}Upload selesai.${RESET}"
}

zivpn_restore_backup() {
  local archive="$1"
  if [ -z "$archive" ] || [ ! -f "$archive" ]; then
    echo -e "${RED}Pakai:${RESET} $0 restore /path/zivpn-backup-XXXX.tar.gz"
    exit 1
  fi

  print_section "Restore ZIVPN UDP"
  echo -e "${YELLOW}Peringatan: restore akan menimpa config/service/binary yang ada.${RESET}"

  run_with_spinner "Menghentikan service" "systemctl stop zivpn.service 2>/dev/null || true"

  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  local tmp="/tmp/zivpn_restore_$ts"
  mkdir -p "$tmp"

  run_with_spinner "Mengekstrak backup" "tar -xzf '$archive' -C '$tmp'"

  echo -e "${CYAN}Mengembalikan file...${RESET}"
  if [ -d "$tmp/files/zivpn" ]; then
    rm -rf /etc/zivpn
    cp -a "$tmp/files/zivpn" /etc/zivpn
  fi

  if [ -f "$tmp/files/zivpn.service" ]; then
    cp -a "$tmp/files/zivpn.service" /etc/systemd/system/zivpn.service
  fi

  if [ -f "$tmp/files/zivpn" ]; then
    cp -a "$tmp/files/zivpn" /usr/local/bin/zivpn
    chmod +x /usr/local/bin/zivpn
  fi

  if [ -f "$tmp/files/menu-zivpn" ]; then
    cp -a "$tmp/files/menu-zivpn" /usr/local/bin/menu-zivpn
    chmod +x /usr/local/bin/menu-zivpn
  fi

  run_with_spinner "Reload systemd" "systemctl daemon-reload"

  echo -e "${CYAN}Mengembalikan rule iptables...${RESET}"
  if [ -f "$tmp/iptables.rules" ]; then
    iptables-restore < "$tmp/iptables.rules" 2>/dev/null || echo -e "${YELLOW}iptables-restore gagal (cek kompatibilitas rules).${RESET}"
  fi
  if [ -f "$tmp/ip6tables.rules" ]; then
    ip6tables-restore < "$tmp/ip6tables.rules" 2>/dev/null || true
  fi

  ensure_zivpn_iptables_persist || true

  run_with_spinner "Mengaktifkan service" "systemctl enable zivpn.service >/dev/null 2>&1 || true"
  run_with_spinner "Menjalankan service" "systemctl start zivpn.service"

  rm -rf "$tmp"
  echo -e "${GREEN}Restore selesai.${RESET}"
}

# =========================
# INSTALL
# =========================
do_install() {
  print_section "Cek instalasi ZIVPN UDP sebelumnya"
  if [ -f /usr/local/bin/zivpn ] || [ -f /etc/systemd/system/zivpn.service ] || [ -d /etc/zivpn ]; then
    echo -e "${YELLOW}ZIVPN terdeteksi sudah terpasang. Akan dilakukan reinstall (hapus lalu install ulang).${RESET}"
    zivpn_uninstall
  fi

  print_section "Update sistem"
  run_with_spinner "Update & upgrade paket" "apt-get update -y && apt-get upgrade -y"

  print_section "Install paket pendukung"
  run_with_spinner "Install jq, curl, wget, zip, unzip" "apt-get install -y jq curl wget zip unzip ca-certificates openssl"

  print_section "Download ZIVPN UDP"
  echo -e "${CYAN}Mengunduh binary ZIVPN...${RESET}"
  systemctl stop zivpn.service &>/dev/null || true
  wget -q https://github.com/ChristopherAGT/zivpn-tunnel-udp/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64 -O /usr/local/bin/zivpn
  chmod +x /usr/local/bin/zivpn

  echo -e "${CYAN}Menyiapkan konfigurasi...${RESET}"
  mkdir -p /etc/zivpn
  wget -q https://raw.githubusercontent.com/welwel11/project5/main/config.json -O /etc/zivpn/config.json

  print_section "Membuat sertifikat SSL"
  run_with_spinner "Membuat sertifikat SSL" "openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 -subj '/C=US/ST=California/L=Los Angeles/O=Example Corp/OU=IT Department/CN=zivpn' -keyout /etc/zivpn/zivpn.key -out /etc/zivpn/zivpn.crt"

  print_section "Optimasi parameter sistem"
  sysctl -w net.core.rmem_max=16777216 &>/dev/null
  sysctl -w net.core.wmem_max=16777216 &>/dev/null

  print_section "Membuat service systemd"
  cat <<EOF > /etc/systemd/system/zivpn.service
[Unit]
Description=ZIVPN UDP VPN Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/zivpn
ExecStart=/usr/local/bin/zivpn server -c /etc/zivpn/config.json
Restart=always
RestartSec=3
Environment=ZIVPN_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

  print_section "Menjalankan dan mengaktifkan service"
  systemctl daemon-reload
  systemctl enable zivpn.service
  systemctl start zivpn.service

  ensure_zivpn_iptables_persist

  print_section "Install panel menu"
  run_with_spinner "Mengunduh menu panel (menu-zivpn)" "wget -q https://raw.githubusercontent.com/welwel11/project5/main/panel-udp-zivpn.sh -O /usr/local/bin/menu-zivpn && chmod +x /usr/local/bin/menu-zivpn"

  if [ "$AUTO_MENU_AFTER_REBOOT" = "1" ]; then
    setup_autorun_menu_always
  fi

  print_section "Selesai"
  rm -f install-amd.sh install-amd.tmp install-amd.log &>/dev/null || true
  echo -e "${GREEN}ZIVPN UDP berhasil diinstall.${RESET}"
  echo -e "${GREEN}Saat login root berikutnya, menu-zivpn akan terbuka otomatis.${RESET}"

  if [ "$AUTO_REBOOT_AFTER_INSTALL" = "1" ]; then
    echo -e "${YELLOW}Server akan reboot dalam 5 detik...${RESET}"
    sleep 5
    reboot
  else
    echo -e "${YELLOW}Reboot disarankan agar service dan rule persistent lebih stabil.${RESET}"
  fi
}

# =========================
# MAIN
# =========================
need_root

MODE="${1:-install}"
case "$MODE" in
  install)         do_install ;;
  reinstall)       do_install ;;
  uninstall)       zivpn_uninstall ;;
  tools-backup)    ins_backup_tools ;;
  backup)          zivpn_make_backup >/dev/null ;;
  upload)          zivpn_upload_backup_rclone "$2" "$3" ;;
  restore)         zivpn_restore_backup "$2" ;;
  fix-iptables)    ensure_zivpn_iptables_persist ;;
  enable-autorun)  setup_autorun_menu_always ;;
  disable-autorun) disable_autorun_menu ;;
  *)
    echo -e "${YELLOW}Cara pakai:${RESET}"
    echo -e "  $0 install                   # install (auto reinstall jika sudah ada)"
    echo -e "  $0 reinstall                 # reinstall paksa"
    echo -e "  $0 uninstall                 # hapus ZIVPN saja"
    echo -e "  $0 tools-backup              # install rclone/tar/gzip"
    echo -e "  $0 backup                    # backup lokal ke $BACKUP_DIR"
    echo -e "  $0 upload <file> [remote]    # upload via rclone"
    echo -e "  $0 restore <file>            # restore dari backup tar.gz"
    echo -e "  $0 fix-iptables              # terapkan + simpan iptables persistent"
    echo -e "  $0 enable-autorun            # aktifkan auto buka menu saat login root"
    echo -e "  $0 disable-autorun           # matikan auto buka menu saat login root"
    exit 1
    ;;
esac