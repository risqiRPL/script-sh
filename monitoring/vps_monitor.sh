#!/bin/bash
# ============================================================
#  VPS MONITORING SCRIPT - by risqiRPL (Modular Version)
#  Monitors: Server, SSL, Resources, Services, Performance
#  Notifications via Telegram Bot
# ============================================================

# ─────────────────────────────────────────────
#  LOAD KONFIGURASI
# ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/monitor.conf"
MODULES_DIR="${SCRIPT_DIR}/modules"

# Override config file jika ada argumen --config
for arg in "$@"; do
  if [[ "$arg" == "--config" ]]; then
    shift
    CONFIG_FILE="$1"
    shift
    break
  fi
done

if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
else
  echo "ERROR: Config file tidak ditemukan di $CONFIG_FILE"
  exit 1
fi

# ─────────────────────────────────────────────
#  INTERNAL VARIABLES
# ─────────────────────────────────────────────
ALERT_TRIGGERED=false
REPORT_SECTIONS=()
ALERT_MESSAGES=""
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
DATE_SHORT=$(date '+%d/%m/%Y %H:%M')
LOCK_FILE="/tmp/vps_monitor_$(echo "$SERVER_NAME" | tr ' ' '_').lock"

# Emoji icons
ICON_OK="✅"
ICON_WARN="⚠️"
ICON_CRIT="🔴"
ICON_INFO="ℹ️"
ICON_SERVER="🖥️"
ICON_WEB="🌐"
ICON_SSL="🔒"
ICON_CPU="⚡"
ICON_RAM="💾"
ICON_DISK="💿"
ICON_SERVICE="⚙️"
ICON_SPEED="🚀"
ICON_REPORT="📊"
ICON_ALERT="🚨"

# ─────────────────────────────────────────────
#  LOAD MODULES
# ─────────────────────────────────────────────
if [ -d "$MODULES_DIR" ]; then
  for module in "$MODULES_DIR"/*.sh; do
    if [ -f "$module" ]; then
      source "$module"
    fi
  done
else
  echo "ERROR: Folder modules tidak ditemukan di $MODULES_DIR"
  exit 1
fi

# ─────────────────────────────────────────────
#  CORE FUNCTIONS (Helpers)
# ─────────────────────────────────────────────

check_deps() {
  local missing=()
  for cmd in curl bc; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: Dependency tidak ditemukan: ${missing[*]}"
    echo "Install dengan: apt install ${missing[*]} -y"
    exit 1
  fi
}

log() {
  local level="${2:-INFO}"
  local log_entry="[$TIMESTAMP] [$level] $1"
  
  if [ -f "$LOG_FILE" ]; then
    local size_mb=$(du -m "$LOG_FILE" 2>/dev/null | awk '{print $1}')
    if [ -n "$size_mb" ] && [ "$size_mb" -ge "${LOG_MAX_SIZE_MB:-10}" ]; then
      mv "$LOG_FILE" "${LOG_FILE}.old"
      echo "[$TIMESTAMP] [INFO] Log dirotasi (${size_mb}MB)" > "$LOG_FILE"
    fi
  fi
  
  echo "$log_entry" >> "$LOG_FILE" 2>/dev/null || true
}

send_telegram() {
  local message="$1"
  local parse_mode="${2:-HTML}"
  
  if [[ "$TELEGRAM_BOT_TOKEN" == "ISI_BOT_TOKEN_KAMU" ]] || [[ -z "$TELEGRAM_BOT_TOKEN" ]]; then
    echo "[WARN] Telegram token belum dikonfigurasi!"
    return 1
  fi
  
  local response
  response=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${message}" \
    --data-urlencode "parse_mode=${parse_mode}" \
    --data-urlencode "disable_web_page_preview=true" \
    --max-time 15 \
    --retry 2 \
    --retry-delay 3 2>/dev/null)
  
  if echo "$response" | grep -q '"ok":true'; then
    log "Telegram: pesan berhasil dikirim"
    return 0
  else
    local err=$(echo "$response" | grep -oP '"description":"\K[^"]+' 2>/dev/null)
    log "Telegram ERROR: $err" "ERROR"
    return 1
  fi
}

escape_html() {
  echo "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

bytes_to_human() {
  local bytes=${1:-0}
  if [ "$bytes" -lt 1024 ]; then
    echo "${bytes}B"
  elif [ "$bytes" -lt 1048576 ]; then
    printf "%.1fKB" "$(echo "scale=1; $bytes/1024" | bc 2>/dev/null)"
  elif [ "$bytes" -lt 1073741824 ]; then
    printf "%.1fMB" "$(echo "scale=1; $bytes/1048576" | bc 2>/dev/null)"
  else
    printf "%.2fGB" "$(echo "scale=2; $bytes/1073741824" | bc 2>/dev/null)"
  fi
}

add_section() {
  REPORT_SECTIONS+=("$1")
}

add_alert() {
  ALERT_TRIGGERED=true
  ALERT_MESSAGES+="$1\n\n"
}

print_step() {
  echo -ne "  → $1... "
}

print_ok() {
  echo "OK"
}

check_lock() {
  if [ -f "$LOCK_FILE" ]; then
    local pid
    pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if kill -0 "$pid" 2>/dev/null; then
      log "Script sudah berjalan (PID: $pid). Skip." "WARN"
      exit 0
    fi
  fi
  echo $$ > "$LOCK_FILE"
  trap "rm -f '$LOCK_FILE'" EXIT INT TERM
}

# ─────────────────────────────────────────────
#  MESSAGING LOGIC
# ─────────────────────────────────────────────

send_full_report() {
  local msg="${ICON_REPORT} <b>VPS MONITORING REPORT</b>\n"
  msg+="━━━━━━━━━━━━━━━━━━━━━━━\n"
  msg+="${ICON_SERVER} <b>Server:</b> <code>${SERVER_NAME}</code>\n"
  msg+="🕐 <b>Waktu:</b> <code>${DATE_SHORT} WIB</code>\n"
  msg+="━━━━━━━━━━━━━━━━━━━━━━━\n\n"
  
  local current_msg="$msg"
  for section in "${REPORT_SECTIONS[@]}"; do
    local candidate="${current_msg}${section}\n\n"
    if [ ${#candidate} -gt 3800 ]; then
      send_telegram "$current_msg"
      sleep 1
      current_msg="${section}\n\n"
    else
      current_msg="${current_msg}${section}\n\n"
    fi
  done
  
  current_msg+="━━━━━━━━━━━━━━━━━━━━━━━\n"
  if $ALERT_TRIGGERED; then
    current_msg+="🔴 Ada masalah terdeteksi! Cek alert di atas."
  else
    current_msg+="${ICON_OK} Semua sistem normal."
  fi
  
  send_telegram "$current_msg"
}

send_alert_message() {
  if $ALERT_TRIGGERED; then
    local alert_msg="${ICON_ALERT} <b>⚠️ VPS ALERT! ⚠️</b>\n"
    alert_msg+="━━━━━━━━━━━━━━━━━━━━━━━\n"
    alert_msg+="${ICON_SERVER} Server: <code>${SERVER_NAME}</code>\n"
    alert_msg+="🕐 Waktu: <code>${DATE_SHORT} WIB</code>\n"
    alert_msg+="━━━━━━━━━━━━━━━━━━━━━━━\n\n"
    alert_msg+="${ALERT_MESSAGES}"
    alert_msg+="━━━━━━━━━━━━━━━━━━━━━━━\n"
    alert_msg+="🔧 Segera periksa server!"
    
    send_telegram "$alert_msg"
  fi
}

# ─────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────

main() {
  local mode="${1:-full}"
  
  if [ "$mode" = "test" ]; then
    echo "🔧 Mengirim test ke Telegram..."
    send_telegram "${ICON_OK} <b>TEST BERHASIL! Modular Version</b>
    
${ICON_SERVER} Server: <code>${SERVER_NAME}</code>
🕐 Waktu: <code>${DATE_SHORT} WIB</code>

VPS Monitor (Modular) sudah terhubung! 🚀"
    [ $? -eq 0 ] && echo "✅ Test message terkirim!" || echo "❌ Gagal kirim."
    exit 0
  fi
  
  if [ "$mode" = "status" ]; then
    echo "📊 Pengecekan status VPS (Terminal only)..."
    TELEGRAM_BOT_TOKEN="" 
  fi
  
  touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/vps_monitor.log"
  check_deps
  check_lock
  
  echo "=== 🖥️  VPS Monitor: ${SERVER_NAME} ==="
  log "=== Monitoring dimulai (Modular) ==="
  
  # Jalankan modul (function didefinisikan di modules/*.sh)
  check_server_status
  check_endpoints
  check_ssl
  check_resources
  check_services
  check_performance
  
  case "$mode" in
    alert|alert-only)   send_alert_message ;;
    report|report-only) send_full_report   ;;
    status)             
      for s in "${REPORT_SECTIONS[@]}"; do 
        echo -e "$s" | sed 's/<[^>]*>//g'
        echo "---"
      done 
      ;;
    full|*)
      if $ALERT_TRIGGERED; then send_alert_message; fi
      send_full_report
      ;;
  esac
  
  log "=== Monitoring selesai ==="
}

main "$@"
