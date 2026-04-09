#!/bin/bash
# ============================================================
#  SETUP SCRIPT - VPS Monitor Installer
#  Jalankan ini 1x di VPS untuk setup cron job & permissions
#  
#  Usage: bash setup_monitor.sh
# ============================================================

set -e

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_SCRIPT="${SCRIPT_DIR}/vps_monitor.sh"
CONFIG_FILE="${SCRIPT_DIR}/monitor.conf"
LOG_FILE="/var/log/vps_monitor.log"
CRON_TAG="# vps-monitor-cron"

print_header() {
  echo ""
  echo -e "${CYAN}${BOLD}╔══════════════════════════════════════╗${NC}"
  echo -e "${CYAN}${BOLD}║      VPS MONITOR - SETUP WIZARD      ║${NC}"
  echo -e "${CYAN}${BOLD}╚══════════════════════════════════════╝${NC}"
  echo ""
}

print_step() {
  echo -e "${BLUE}${BOLD}[STEP]${NC} $1"
}

print_ok() {
  echo -e "  ${GREEN}✓${NC} $1"
}

print_warn() {
  echo -e "  ${YELLOW}⚠${NC} $1"
}

print_error() {
  echo -e "  ${RED}✗${NC} $1"
}

print_info() {
  echo -e "  ${CYAN}→${NC} $1"
}

# ── 1. Cek root / sudo ──
check_root() {
  print_step "Cek permission..."
  if [ "$EUID" -ne 0 ]; then
    print_warn "Tidak berjalan sebagai root. Beberapa fitur mungkin terbatas."
    print_info "Untuk fitur penuh, jalankan: sudo bash setup_monitor.sh"
    CAN_WRITE_LOG=false
  else
    CAN_WRITE_LOG=true
    print_ok "Running as root"
  fi
}

# ── 2. Cek dependencies ──
check_dependencies() {
  print_step "Cek dependencies..."
  
  local missing=()
  local deps=(curl bc openssl)
  
  for dep in "${deps[@]}"; do
    if command -v "$dep" &>/dev/null; then
      print_ok "$dep sudah ada ($(command -v "$dep"))"
    else
      print_error "$dep TIDAK DITEMUKAN"
      missing+=("$dep")
    fi
  done
  
  if [ ${#missing[@]} -gt 0 ]; then
    echo ""
    print_warn "Menginstall dependencies yang kurang..."
    if command -v apt-get &>/dev/null; then
      apt-get install -y "${missing[@]}" 2>/dev/null && print_ok "Dependencies diinstall via apt"
    elif command -v yum &>/dev/null; then
      yum install -y "${missing[@]}" 2>/dev/null && print_ok "Dependencies diinstall via yum"
    else
      print_error "Package manager tidak dikenal. Install manual: ${missing[*]}"
      exit 1
    fi
  fi
}

# ── 3. Setup permissions ──
setup_permissions() {
  print_step "Setup file permissions..."
  
  chmod +x "$MONITOR_SCRIPT"
  print_ok "vps_monitor.sh → executable"
  
  chmod 600 "$CONFIG_FILE"
  print_ok "monitor.conf → 600 (private)"
  
  # Setup modules directory
  local modules_dir="${SCRIPT_DIR}/modules"
  if [ -d "$modules_dir" ]; then
    chmod 755 "$modules_dir"
    chmod 644 "$modules_dir"/*.sh 2>/dev/null || true
    print_ok "modules/ → setup complete"
  else
    print_warn "Folder modules/ tidak ditemukan. Pastikan file modul ada!"
  fi
  
  # Setup log file
  if $CAN_WRITE_LOG; then
    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"
    print_ok "Log file: $LOG_FILE"
  else
    # Buat log di /tmp jika tidak ada akses /var/log
    touch "/tmp/vps_monitor.log"
    print_warn "Log disimpan di /tmp/vps_monitor.log (tidak ada akses /var/log)"
    # Update LOG_FILE di config
    if grep -q "^LOG_FILE=" "$CONFIG_FILE"; then
      sed -i "s|^LOG_FILE=.*|LOG_FILE=\"/tmp/vps_monitor.log\"|" "$CONFIG_FILE"
    fi
  fi
}

# ── 4. Konfigurasi interaktif ──
configure_telegram() {
  print_step "Konfigurasi Telegram..."
  echo ""
  
  # Baca config saat ini
  source "$CONFIG_FILE" 2>/dev/null || true
  
  # Token
  if [[ "$TELEGRAM_BOT_TOKEN" == *"ISI_BOT_TOKEN"* ]] || [ -z "$TELEGRAM_BOT_TOKEN" ]; then
    print_warn "Telegram Bot Token belum dikonfigurasi!"
    echo -ne "  ${YELLOW}→ Masukkan Bot Token${NC} (dari @BotFather): "
    read -r new_token
    if [ -n "$new_token" ]; then
      sed -i "s|^TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=\"${new_token}\"|" "$CONFIG_FILE"
      TELEGRAM_BOT_TOKEN="$new_token"
      print_ok "Bot Token disimpan"
    fi
  else
    print_ok "Bot Token sudah ada (${TELEGRAM_BOT_TOKEN:0:10}...)"
  fi
  
  # Chat ID
  if [[ "$TELEGRAM_CHAT_ID" == *"ISI_CHAT_ID"* ]] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    print_warn "Telegram Chat ID belum dikonfigurasi!"
    echo ""
    print_info "Cara dapat Chat ID:"
    print_info "  1. Kirim pesan ke bot kamu"
    print_info "  2. Buka: https://api.telegram.org/bot<TOKEN>/getUpdates"
    print_info "  3. Cari nilai 'chat.id' (negatif = group)"
    echo ""
    echo -ne "  ${YELLOW}→ Masukkan Chat ID${NC}: "
    read -r new_chat_id
    if [ -n "$new_chat_id" ]; then
      sed -i "s|^TELEGRAM_CHAT_ID=.*|TELEGRAM_CHAT_ID=\"${new_chat_id}\"|" "$CONFIG_FILE"
      TELEGRAM_CHAT_ID="$new_chat_id"
      print_ok "Chat ID disimpan"
    fi
  else
    print_ok "Chat ID sudah ada ($TELEGRAM_CHAT_ID)"
  fi
  
  # Server Name
  local default_hostname
  default_hostname=$(hostname 2>/dev/null || echo "VPS-Server")
  echo -ne "  ${CYAN}→ Nama server${NC} [${default_hostname}]: "
  read -r new_name
  new_name="${new_name:-$default_hostname}"
  sed -i "s|^SERVER_NAME=.*|SERVER_NAME=\"${new_name}\"|" "$CONFIG_FILE"
  print_ok "Nama server: $new_name"
}

# ── 5. Test Telegram ──
test_telegram() {
  print_step "Test koneksi Telegram..."
  
  source "$CONFIG_FILE" 2>/dev/null || true
  
  local test_result
  test_result=$(bash "$MONITOR_SCRIPT" test 2>&1)
  
  if echo "$test_result" | grep -q "berhasil"; then
    print_ok "Telegram berhasil! Cek HP kamu."
  else
    print_error "Gagal kirim ke Telegram!"
    print_info "Output: $test_result"
    print_warn "Cek token & chat_id di monitor.conf"
  fi
}

# ── 6. Setup cron job ──
setup_cron() {
  print_step "Setup cron job..."
  echo ""
  echo -e "  ${BOLD}Pilih jadwal monitoring:${NC}"
  echo -e "  ${CYAN}1)${NC} Setiap 5 menit   (hanya alert jika ada masalah)"
  echo -e "  ${CYAN}2)${NC} Setiap 15 menit  (hanya alert)"
  echo -e "  ${CYAN}3)${NC} Setiap 30 menit  (alert + report)"  
  echo -e "  ${CYAN}4)${NC} Setiap jam       (alert + report)"
  echo -e "  ${CYAN}5)${NC} Custom jadwal"
  echo -e "  ${CYAN}6)${NC} Skip (setup manual)"
  echo ""
  echo -ne "  ${YELLOW}→ Pilihan${NC} [3]: "
  read -r cron_choice
  cron_choice="${cron_choice:-3}"
  
  # Hapus cron lama dulu
  crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab - 2>/dev/null || true
  
  local cron_line=""
  case "$cron_choice" in
    1)
      # Setiap 5 menit, kirim alert saja
      cron_line="*/5 * * * * bash ${MONITOR_SCRIPT} alert >> ${LOG_FILE} 2>&1 ${CRON_TAG}"
      print_ok "Cron: Setiap 5 menit (alert only)"
      ;;
    2)
      cron_line="*/15 * * * * bash ${MONITOR_SCRIPT} alert >> ${LOG_FILE} 2>&1 ${CRON_TAG}"
      print_ok "Cron: Setiap 15 menit (alert only)"
      ;;
    3)
      # Alert setiap 5 menit, report setiap 30 menit
      local tmp_cron
      tmp_cron=$(crontab -l 2>/dev/null || true)
      tmp_cron+=$'\n'"*/5 * * * * bash ${MONITOR_SCRIPT} alert >> ${LOG_FILE} 2>&1 ${CRON_TAG}"
      tmp_cron+=$'\n'"*/30 * * * * bash ${MONITOR_SCRIPT} report >> ${LOG_FILE} 2>&1 ${CRON_TAG}"
      echo "$tmp_cron" | crontab -
      print_ok "Cron: Alert setiap 5 menit + Report setiap 30 menit"
      cron_line=""  # Sudah ditambah
      ;;
    4)
      local tmp_cron
      tmp_cron=$(crontab -l 2>/dev/null || true)
      tmp_cron+=$'\n'"*/5 * * * * bash ${MONITOR_SCRIPT} alert >> ${LOG_FILE} 2>&1 ${CRON_TAG}"
      tmp_cron+=$'\n'"0 * * * * bash ${MONITOR_SCRIPT} report >> ${LOG_FILE} 2>&1 ${CRON_TAG}"
      echo "$tmp_cron" | crontab -
      print_ok "Cron: Alert setiap 5 menit + Report setiap jam"
      cron_line=""
      ;;
    5)
      echo -ne "  ${YELLOW}→ Alert cron expression${NC} (contoh: */10 * * * *): "
      read -r custom_alert
      echo -ne "  ${YELLOW}→ Report cron expression${NC} (contoh: 0 * * * *): "
      read -r custom_report
      local tmp_cron
      tmp_cron=$(crontab -l 2>/dev/null || true)
      [ -n "$custom_alert"  ] && tmp_cron+=$'\n'"${custom_alert} bash ${MONITOR_SCRIPT} alert >> ${LOG_FILE} 2>&1 ${CRON_TAG}"
      [ -n "$custom_report" ] && tmp_cron+=$'\n'"${custom_report} bash ${MONITOR_SCRIPT} report >> ${LOG_FILE} 2>&1 ${CRON_TAG}"
      echo "$tmp_cron" | crontab -
      print_ok "Cron custom disimpan"
      cron_line=""
      ;;
    6)
      print_warn "Cron tidak disetup. Setup manual dengan: crontab -e"
      return
      ;;
  esac
  
  # Tambahkan cron_line jika ada
  if [ -n "$cron_line" ]; then
    (crontab -l 2>/dev/null || true; echo "$cron_line") | crontab -
  fi
  
  echo ""
  print_info "Cron aktif:"
  crontab -l 2>/dev/null | grep "$CRON_TAG" | while read -r line; do
    print_info "  $line"
  done
}

# ── 7. Jalankan test awal ──
run_initial_check() {
  print_step "Jalankan pengecekan awal..."
  echo ""
  echo -ne "  ${YELLOW}→ Jalankan full check sekarang?${NC} [Y/n]: "
  read -r run_now
  run_now="${run_now:-Y}"
  
  if [[ "$run_now" =~ ^[Yy]$ ]]; then
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    bash "$MONITOR_SCRIPT" status
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  fi
}

# ── Summary ──
print_summary() {
  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║         SETUP SELESAI! ✅             ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}File:${NC}"
  echo -e "  • Script:  ${CYAN}${MONITOR_SCRIPT}${NC}"
  echo -e "  • Config:  ${CYAN}${CONFIG_FILE}${NC}"
  echo -e "  • Log:     ${CYAN}${LOG_FILE}${NC}"
  echo ""
  echo -e "  ${BOLD}Perintah berguna:${NC}"
  echo -e "  • ${CYAN}bash ${MONITOR_SCRIPT} test${NC}    → Test Telegram"
  echo -e "  • ${CYAN}bash ${MONITOR_SCRIPT} status${NC}  → Cek tanpa kirim Telegram"
  echo -e "  • ${CYAN}bash ${MONITOR_SCRIPT} alert${NC}   → Kirim alert (jika ada masalah)"
  echo -e "  • ${CYAN}bash ${MONITOR_SCRIPT} report${NC}  → Kirim full report"
  echo -e "  • ${CYAN}bash ${MONITOR_SCRIPT}${NC}         → Full check + kirim semua"
  echo -e "  • ${CYAN}crontab -l${NC}               → Lihat jadwal cron"
  echo -e "  • ${CYAN}tail -f ${LOG_FILE}${NC}"
  echo "                         → Pantau log realtime"
  echo ""
}

# ── MAIN ──
main() {
  print_header
  check_root
  echo ""
  check_dependencies
  echo ""
  setup_permissions
  echo ""
  configure_telegram
  echo ""
  test_telegram
  echo ""
  setup_cron
  echo ""
  run_initial_check
  print_summary
}

main "$@"
