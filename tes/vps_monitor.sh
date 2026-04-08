#!/bin/bash
# ============================================================
#  VPS MONITORING SCRIPT - by risqiRPL
#  Monitors: Server, SSL, Resources, Services, Performance
#  Notifications via Telegram Bot
#  
#  Usage:
#    ./vps_monitor.sh           → Full check + kirim semua
#    ./vps_monitor.sh test      → Test koneksi Telegram
#    ./vps_monitor.sh alert     → Kirim alert saja (jika ada masalah)
#    ./vps_monitor.sh report    → Kirim full report saja
#    ./vps_monitor.sh status    → Print status ke terminal (no Telegram)
#    ./vps_monitor.sh --config /path/to/monitor.conf
# ============================================================

# ─────────────────────────────────────────────
#  LOAD KONFIGURASI
# ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/monitor.conf"

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
  # Default config jika file tidak ada
  TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-ISI_BOT_TOKEN_KAMU}"
  TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-ISI_CHAT_ID_KAMU}"
  SERVER_NAME="${SERVER_NAME:-$(hostname)}"
  CPU_THRESHOLD="${CPU_THRESHOLD:-80}"
  RAM_THRESHOLD="${RAM_THRESHOLD:-85}"
  DISK_THRESHOLD="${DISK_THRESHOLD:-85}"
  SSL_WARN_DAYS="${SSL_WARN_DAYS:-14}"
  RESPONSE_WARN_MS="${RESPONSE_WARN_MS:-3000}"
  LOG_FILE="${LOG_FILE:-/var/log/vps_monitor.log}"
  LOG_MAX_SIZE_MB="${LOG_MAX_SIZE_MB:-10}"
  
  ENDPOINTS=(
    "Website Utama|https://example.com"
  )
  SERVICES=(
    "Nginx|nginx"
  )
  SSL_DOMAINS=(
    "example.com"
  )
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
#  DEPENDENCY CHECK
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

# ─────────────────────────────────────────────
#  HELPER FUNCTIONS
# ─────────────────────────────────────────────

log() {
  local level="${2:-INFO}"
  local log_entry="[$TIMESTAMP] [$level] $1"
  
  # Rotasi log jika terlalu besar
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

# Progress indicator untuk terminal
print_step() {
  echo -ne "  → $1... "
}
print_ok() {
  echo "OK"
}

# ─────────────────────────────────────────────
#  LOCK FILE - Cegah double run
# ─────────────────────────────────────────────
check_lock() {
  if [ -f "$LOCK_FILE" ]; then
    local pid
    pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if kill -0 "$pid" 2>/dev/null; then
      log "Script sudah berjalan (PID: $pid). Skip." "WARN"
      echo "Script sedang berjalan (PID: $pid). Keluar."
      exit 0
    fi
  fi
  echo $$ > "$LOCK_FILE"
  trap "rm -f '$LOCK_FILE'" EXIT INT TERM
}

# ─────────────────────────────────────────────
#  1. SERVER STATUS (Uptime + Internet)
# ─────────────────────────────────────────────
check_server_status() {
  print_step "Cek server status"
  
  local content="${ICON_SERVER} <b>SERVER STATUS</b>\n"
  content+="<b>─────────────────</b>\n"
  
  # Uptime
  local uptime_str
  uptime_str=$(uptime -p 2>/dev/null | sed 's/^up //' || uptime | awk -F'up ' '{print $2}' | awk -F',' '{print $1}' | xargs)
  
  # Load average
  local load_1 load_5 load_15
  read -r load_1 load_5 load_15 < <(uptime | grep -oP 'load average[s]?: \K.*' | tr ',' ' ' | awk '{print $1, $2, $3}')
  
  # Internet check (ping + DNS)
  local internet_ok=true
  if ! ping -c 1 -W 3 8.8.8.8 > /dev/null 2>&1; then
    if ! curl -s --max-time 5 https://google.com > /dev/null 2>&1; then
      internet_ok=false
    fi
  fi
  
  if $internet_ok; then
    local inet_status="${ICON_OK} Online"
  else
    local inet_status="${ICON_CRIT} <b>OFFLINE!</b>"
    add_alert "${ICON_CRIT} <b>INTERNET DOWN!</b>\nServer <code>${SERVER_NAME}</code> tidak bisa menjangkau internet!\nWaktu: <code>${DATE_SHORT}</code>"
  fi
  
  content+="  ${ICON_OK} Uptime: <code>${uptime_str}</code>\n"
  content+="  ${ICON_INFO} Internet: ${inet_status}\n"
  content+="  📈 Load: <code>${load_1} | ${load_5} | ${load_15}</code> (1m|5m|15m)"
  
  add_section "$content"
  print_ok
  log "Server: uptime=$uptime_str, internet=$internet_ok, load=$load_1/$load_5/$load_15"
}

# ─────────────────────────────────────────────
#  2. ENDPOINT STATUS
# ─────────────────────────────────────────────
check_endpoints() {
  print_step "Cek endpoints"
  
  local content="${ICON_WEB} <b>ENDPOINT STATUS</b>\n"
  content+="<b>─────────────────</b>\n"
  
  for entry in "${ENDPOINTS[@]}"; do
    local name url
    name=$(echo "$entry" | cut -d'|' -f1)
    url=$(echo "$entry" | cut -d'|' -f2)
    
    local result
    result=$(curl -o /dev/null -s -w "%{http_code}|%{time_total}" \
      --max-time 10 --connect-timeout 5 -L "$url" 2>/dev/null)
    
    local http_code time_ms
    http_code=$(echo "$result" | cut -d'|' -f1)
    local time_raw
    time_raw=$(echo "$result" | cut -d'|' -f2)
    time_ms=$(echo "$time_raw * 1000 / 1" | bc 2>/dev/null || echo "0")
    
    local status
    if [ -z "$http_code" ] || [ "$http_code" = "000" ]; then
      status="${ICON_CRIT} <b>DOWN / Timeout</b>"
      add_alert "${ICON_CRIT} <b>ENDPOINT DOWN!</b>\n• Nama: <code>$(escape_html "$name")</code>\n• URL: <code>${url}</code>\n• Status: Timeout / Unreachable"
    elif [ "$http_code" -ge 200 ] && [ "$http_code" -lt 400 ] 2>/dev/null; then
      if [ "$time_ms" -gt "$RESPONSE_WARN_MS" ] 2>/dev/null; then
        status="${ICON_WARN} HTTP ${http_code} (${time_ms}ms - <b>LAMBAT</b>)"
        add_alert "${ICON_WARN} <b>ENDPOINT LAMBAT!</b>\n• Nama: <code>$(escape_html "$name")</code>\n• Response: <code>${time_ms}ms</code> (batas: ${RESPONSE_WARN_MS}ms)"
      else
        status="${ICON_OK} HTTP ${http_code} (<code>${time_ms}ms</code>)"
      fi
    elif [ "$http_code" -ge 400 ] 2>/dev/null; then
      status="${ICON_CRIT} HTTP ${http_code} - Error"
      add_alert "${ICON_CRIT} <b>ENDPOINT ERROR!</b>\n• Nama: <code>$(escape_html "$name")</code>\n• HTTP: <code>${http_code}</code>\n• URL: <code>${url}</code>"
    else
      status="${ICON_WARN} HTTP ${http_code}"
    fi
    
    content+="  • <b>$(escape_html "$name")</b>: ${status}\n"
    log "Endpoint [$name]: HTTP=$http_code, ${time_ms}ms"
  done
  
  add_section "$content"
  print_ok
}

# ─────────────────────────────────────────────
#  3. SSL CERTIFICATE CHECK
# ─────────────────────────────────────────────
check_ssl() {
  print_step "Cek SSL certificates"
  
  local content="${ICON_SSL} <b>SSL CERTIFICATE</b>\n"
  content+="<b>─────────────────</b>\n"
  
  if ! command -v openssl &>/dev/null; then
    content+="  ${ICON_WARN} openssl tidak tersedia"
    add_section "$content"
    print_ok
    return
  fi
  
  for domain in "${SSL_DOMAINS[@]}"; do
    local expiry_raw
    expiry_raw=$(echo | timeout 8 openssl s_client \
      -connect "${domain}:443" \
      -servername "$domain" \
      -verify_quiet 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null \
      | cut -d'=' -f2)
    
    if [ -z "$expiry_raw" ]; then
      content+="  • <b>$(escape_html "$domain")</b>: ${ICON_WARN} Gagal ambil cert\n"
      log "SSL [$domain]: gagal cek" "WARN"
      continue
    fi
    
    # Konversi tanggal (Linux & macOS compatible)
    local expiry_epoch now_epoch days_left expiry_fmt
    expiry_epoch=$(date -d "$expiry_raw" +%s 2>/dev/null \
      || date -j -f "%b %d %T %Y %Z" "$expiry_raw" +%s 2>/dev/null \
      || echo "0")
    now_epoch=$(date +%s)
    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
    expiry_fmt=$(date -d "$expiry_raw" '+%d %b %Y' 2>/dev/null \
      || date -j -f "%b %d %T %Y %Z" "$expiry_raw" '+%d %b %Y' 2>/dev/null \
      || echo "$expiry_raw")
    
    local ssl_status bar=""
    
    if [ "$days_left" -le 0 ]; then
      ssl_status="${ICON_CRIT} <b>EXPIRED!</b>"
      bar="🔴🔴🔴🔴🔴"
      add_alert "${ICON_CRIT} <b>SSL EXPIRED!</b>\n• Domain: <code>${domain}</code>\n• Status: SUDAH EXPIRED\n• Tanggal: ${expiry_fmt}\n⚠️ Segera renew!"
    elif [ "$days_left" -le 7 ]; then
      ssl_status="${ICON_CRIT} ${days_left} hari lagi!"
      bar="🔴🔴🔴🔴⬜"
      add_alert "${ICON_CRIT} <b>SSL KRITIS!</b>\n• Domain: <code>${domain}</code>\n• Sisa: <b>${days_left} hari</b>\n• Expire: ${expiry_fmt}"
    elif [ "$days_left" -le "$SSL_WARN_DAYS" ]; then
      ssl_status="${ICON_WARN} ${days_left} hari lagi"
      bar="🟡🟡🟡⬜⬜"
      add_alert "${ICON_WARN} <b>SSL HAMPIR EXPIRE!</b>\n• Domain: <code>${domain}</code>\n• Sisa: <b>${days_left} hari</b>\n• Expire: ${expiry_fmt}\nJangan lupa renew!"
    elif [ "$days_left" -le 30 ]; then
      ssl_status="${ICON_WARN} ${days_left} hari"
      bar="🟡🟡🟢🟢🟢"
    else
      ssl_status="${ICON_OK} ${days_left} hari"
      bar="🟢🟢🟢🟢🟢"
    fi
    
    content+="  • <b>$(escape_html "$domain")</b>: ${ssl_status}\n"
    content+="    📅 <code>${expiry_fmt}</code> ${bar}\n"
    log "SSL [$domain]: $days_left hari ($expiry_fmt)"
  done
  
  add_section "$content"
  print_ok
}

# ─────────────────────────────────────────────
#  4. RESOURCE USAGE (CPU, RAM, Disk)
# ─────────────────────────────────────────────
check_resources() {
  print_step "Cek resources"
  
  local content="${ICON_CPU} <b>RESOURCE USAGE</b>\n"
  content+="<b>─────────────────</b>\n"
  
  # ── CPU Usage via /proc/stat (lebih akurat) ──
  local cpu_used="N/A"
  if [ -f /proc/stat ]; then
    local c1=( $(grep '^cpu ' /proc/stat | awk '{print $2,$3,$4,$5,$6,$7,$8}') )
    sleep 1
    local c2=( $(grep '^cpu ' /proc/stat | awk '{print $2,$3,$4,$5,$6,$7,$8}') )
    local total1=0 total2=0
    for v in "${c1[@]}"; do (( total1 += v )); done
    for v in "${c2[@]}"; do (( total2 += v )); done
    local idle1=${c1[3]}
    local idle2=${c2[3]}
    local dtotal=$(( total2 - total1 ))
    local didle=$(( idle2 - idle1 ))
    if [ "$dtotal" -gt 0 ]; then
      cpu_used=$(( 100 * (dtotal - didle) / dtotal ))
    fi
  fi
  
  # Bar visualizer untuk CPU
  make_bar() {
    local pct=${1:-0}
    local filled=$(( pct / 10 ))
    local bar=""
    for (( i=0; i<filled && i<10; i++ )); do bar+="█"; done
    for (( i=filled; i<10; i++ )); do bar+="░"; done
    echo "$bar"
  }
  
  local cpu_bar
  cpu_bar=$(make_bar "$cpu_used")
  local cpu_icon
  if [ "$cpu_used" != "N/A" ]; then
    if [ "$cpu_used" -ge "$CPU_THRESHOLD" ] 2>/dev/null; then
      cpu_icon="${ICON_CRIT}"
      add_alert "${ICON_CRIT} <b>CPU USAGE TINGGI!</b>\n• Server: <code>${SERVER_NAME}</code>\n• CPU: <b>${cpu_used}%</b> (batas: ${CPU_THRESHOLD}%)"
    elif [ "$cpu_used" -ge $(( CPU_THRESHOLD - 15 )) ] 2>/dev/null; then
      cpu_icon="${ICON_WARN}"
    else
      cpu_icon="${ICON_OK}"
    fi
  else
    cpu_icon="${ICON_INFO}"
  fi
  content+="${ICON_CPU} CPU: ${cpu_icon} <code>${cpu_used}% [${cpu_bar}]</code>\n"
  
  # ── RAM Usage ──
  local ram_info ram_total ram_used ram_free ram_pct
  ram_info=$(free -m 2>/dev/null | grep '^Mem:')
  ram_total=$(echo "$ram_info" | awk '{print $2}')
  ram_used=$(echo "$ram_info" | awk '{print $3}')
  ram_free=$(echo "$ram_info" | awk '{print $4}')
  ram_buff=$(echo "$ram_info" | awk '{print $6}')
  
  if [ -n "$ram_total" ] && [ "$ram_total" -gt 0 ]; then
    ram_pct=$(( ram_used * 100 / ram_total ))
  else
    ram_pct=0
    ram_total="N/A"
    ram_used="N/A"
  fi
  
  local ram_bar
  ram_bar=$(make_bar "$ram_pct")
  local ram_icon
  if [ "$ram_pct" -ge "$RAM_THRESHOLD" ] 2>/dev/null; then
    ram_icon="${ICON_CRIT}"
    add_alert "${ICON_CRIT} <b>RAM HAMPIR PENUH!</b>\n• Server: <code>${SERVER_NAME}</code>\n• RAM: <b>${ram_pct}%</b> (${ram_used}MB / ${ram_total}MB)\n• Sisa: ${ram_free}MB"
  elif [ "$ram_pct" -ge $(( RAM_THRESHOLD - 15 )) ] 2>/dev/null; then
    ram_icon="${ICON_WARN}"
  else
    ram_icon="${ICON_OK}"
  fi
  content+="${ICON_RAM} RAM: ${ram_icon} <code>${ram_pct}% [${ram_bar}]</code>\n"
  content+="       <code>Used: ${ram_used}MB / Total: ${ram_total}MB</code>\n"
  
  # ── Disk Usage semua partisi penting ──
  content+="${ICON_DISK} Disk:\n"
  while IFS= read -r line; do
    local mount size used avail pct
    mount=$(echo "$line"  | awk '{print $6}')
    size=$(echo "$line"   | awk '{print $2}')
    used=$(echo "$line"   | awk '{print $3}')
    avail=$(echo "$line"  | awk '{print $4}')
    pct=$(echo "$line"    | awk '{print $5}' | tr -d '%')
    
    local disk_bar disk_icon
    disk_bar=$(make_bar "$pct")
    
    if [ "$pct" -ge "$DISK_THRESHOLD" ] 2>/dev/null; then
      disk_icon="${ICON_CRIT}"
      add_alert "${ICON_CRIT} <b>DISK HAMPIR PENUH!</b>\n• Mount: <code>${mount}</code>\n• Used: <b>${pct}%</b> (${used} / ${size})\n• Sisa: <b>${avail}</b>"
    elif [ "$pct" -ge $(( DISK_THRESHOLD - 15 )) ] 2>/dev/null; then
      disk_icon="${ICON_WARN}"
    else
      disk_icon="${ICON_OK}"
    fi
    
    content+="    ${disk_icon} <code>${mount}</code>: <code>${pct}% [${disk_bar}]</code>\n"
    content+="       <code>${used} / ${size} (sisa ${avail})</code>\n"
    
    log "Disk [$mount]: $pct% used ($used/$size)"
  done < <(df -h --output=source,size,used,avail,pcent,target 2>/dev/null | tail -n +2 \
    | grep -E '^(/dev/|tmpfs)' \
    | grep -vE 'tmpfs|udev|loop' \
    | sort -k6)
  
  add_section "$content"
  print_ok
  log "CPU: $cpu_used%, RAM: $ram_pct%"
}

# ─────────────────────────────────────────────
#  5. SERVICE STATUS
# ─────────────────────────────────────────────
check_services() {
  print_step "Cek services"
  
  local content="${ICON_SERVICE} <b>SERVICE STATUS</b>\n"
  content+="<b>─────────────────</b>\n"
  
  local svc_ok=0 svc_down=0
  
  for entry in "${SERVICES[@]}"; do
    local name svc
    name=$(echo "$entry" | cut -d'|' -f1)
    svc=$(echo "$entry"  | cut -d'|' -f2)
    
    local status mem_usage=""
    
    if command -v systemctl &>/dev/null; then
      local is_active
      is_active=$(systemctl is-active "$svc" 2>/dev/null)
      local is_enabled
      is_enabled=$(systemctl is-enabled "$svc" 2>/dev/null | head -1)
      
      # Ambil memory usage dari service jika tersedia
      local svc_mem
      svc_mem=$(systemctl show "$svc" --property=MemoryCurrent 2>/dev/null | cut -d'=' -f2)
      if [ -n "$svc_mem" ] && [ "$svc_mem" != "[not set]" ] && [ "$svc_mem" -gt 0 ] 2>/dev/null; then
        mem_usage=" | RAM: $(bytes_to_human "$svc_mem")"
      fi
      
      case "$is_active" in
        active)
          status="${ICON_OK} running"
          (( svc_ok++ ))
          ;;
        inactive|failed)
          status="${ICON_CRIT} <b>STOPPED/FAILED</b>"
          (( svc_down++ ))
          local svc_log
          svc_log=$(journalctl -u "$svc" --no-pager -n 3 --output=short 2>/dev/null | tail -3 | tr '\n' ' ')
          add_alert "${ICON_CRIT} <b>SERVICE MATI!</b>\n• Service: <code>$(escape_html "$name")</code> (<code>${svc}</code>)\n• Status: <b>${is_active}</b>\n• Log: <code>$(escape_html "${svc_log:0:200}")</code>"
          ;;
        activating)
          status="${ICON_WARN} starting..."
          (( svc_ok++ ))
          ;;
        *)
          status="${ICON_WARN} ${is_active} (not found?)"
          ;;
      esac
      
      content+="  • <b>$(escape_html "$name")</b>: ${status}${mem_usage}\n"
    else
      # Fallback: cek via process name
      if pgrep -x "$svc" > /dev/null 2>&1 || pgrep -f "$svc" > /dev/null 2>&1; then
        status="${ICON_OK} running"
        (( svc_ok++ ))
      else
        status="${ICON_CRIT} not found"
        (( svc_down++ ))
        add_alert "${ICON_CRIT} <b>SERVICE TIDAK BERJALAN!</b>\n• Service: <code>$(escape_html "$name")</code>\n• Process: <code>${svc}</code>"
      fi
      content+="  • <b>$(escape_html "$name")</b>: ${status}\n"
    fi
    
    log "Service [$name/$svc]: $status"
  done
  
  # Summary
  content+="\n  📋 Summary: ${ICON_OK} ${svc_ok} running | ${ICON_CRIT} ${svc_down} down"
  
  add_section "$content"
  print_ok
}

# ─────────────────────────────────────────────
#  6. PERFORMANCE (Speed & Error Rate)
# ─────────────────────────────────────────────
check_performance() {
  print_step "Cek performance"
  
  local content="${ICON_SPEED} <b>PERFORMANCE</b>\n"
  content+="<b>─────────────────</b>\n"
  
  # ── Network I/O ──
  local net_iface
  net_iface=$(ip route 2>/dev/null | grep default | awk '{print $5}' | head -1)
  
  if [ -n "$net_iface" ] && [ -f "/sys/class/net/${net_iface}/statistics/rx_bytes" ]; then
    local rx1 tx1 rx2 tx2
    rx1=$(cat "/sys/class/net/${net_iface}/statistics/rx_bytes")
    tx1=$(cat "/sys/class/net/${net_iface}/statistics/tx_bytes")
    sleep 1
    rx2=$(cat "/sys/class/net/${net_iface}/statistics/rx_bytes")
    tx2=$(cat "/sys/class/net/${net_iface}/statistics/tx_bytes")
    
    local rx_rate=$(( rx2 - rx1 ))
    local tx_rate=$(( tx2 - tx1 ))
    
    content+="🌐 Network (<code>${net_iface}</code>):\n"
    content+="   🔽 RX: <code>$(bytes_to_human $rx_rate)/s</code>\n"
    content+="   🔼 TX: <code>$(bytes_to_human $tx_rate)/s</code>\n"
  fi
  
  # ── Response Time Detail per Endpoint ──
  content+="📡 Response Time:\n"
  
  local total_ok=0 total_error=0 total_time_ms=0
  
  for entry in "${ENDPOINTS[@]}"; do
    local name url
    name=$(echo "$entry" | cut -d'|' -f1)
    url=$(echo "$entry"  | cut -d'|' -f2)
    
    # Ambil detail timing breakdown
    local result
    result=$(curl -o /dev/null -s \
      -w "%{http_code}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}|%{time_total}" \
      --max-time 10 --connect-timeout 5 -L "$url" 2>/dev/null)
    
    local http_code t_dns t_conn t_ssl t_ttfb t_total
    http_code=$(echo "$result" | cut -d'|' -f1)
    t_dns=$(echo   "$result" | cut -d'|' -f2)
    t_conn=$(echo  "$result" | cut -d'|' -f3)
    t_ssl=$(echo   "$result" | cut -d'|' -f4)
    t_ttfb=$(echo  "$result" | cut -d'|' -f5)
    t_total=$(echo "$result" | cut -d'|' -f6)
    
    ms() { echo "${1} * 1000 / 1" | bc 2>/dev/null || echo "0"; }
    local dns_ms conn_ms ssl_ms ttfb_ms total_ms
    dns_ms=$(ms "$t_dns")
    conn_ms=$(ms "$t_conn")
    ssl_ms=$(ms "$t_ssl")
    ttfb_ms=$(ms "$t_ttfb")
    total_ms=$(ms "$t_total")
    
    local perf_icon
    if [ "$http_code" = "000" ] || [ -z "$http_code" ]; then
      content+="  • <b>$(escape_html "$name")</b>: ${ICON_CRIT} Timeout\n"
      (( total_error++ ))
    elif [ "$http_code" -ge 400 ] 2>/dev/null; then
      content+="  • <b>$(escape_html "$name")</b>: ${ICON_CRIT} HTTP ${http_code}\n"
      (( total_error++ ))
    else
      (( total_ok++ ))
      if [ "$total_ms" -gt "$RESPONSE_WARN_MS" ] 2>/dev/null; then
        perf_icon="${ICON_WARN}"
      else
        perf_icon="${ICON_OK}"
      fi
      total_time_ms=$(( total_time_ms + total_ms ))
      content+="  • <b>$(escape_html "$name")</b>: ${perf_icon} <code>${total_ms}ms</code>\n"
      content+="    DNS:<code>${dns_ms}ms</code> TCP:<code>${conn_ms}ms</code> TTFB:<code>${ttfb_ms}ms</code>\n"
    fi
  done
  
  # ── Error Rate ──
  local total_eps=$(( total_ok + total_error ))
  local error_rate=0
  if [ "$total_eps" -gt 0 ]; then
    error_rate=$(( total_error * 100 / total_eps ))
  fi
  
  # ── Avg response time ──
  local avg_ms=0
  if [ "$total_ok" -gt 0 ]; then
    avg_ms=$(( total_time_ms / total_ok ))
  fi
  
  local err_icon
  if [ "$error_rate" -ge 50 ]; then
    err_icon="${ICON_CRIT}"
    add_alert "${ICON_CRIT} <b>ERROR RATE TINGGI!</b>\n• Error: <b>${error_rate}%</b> (${total_error}/${total_eps} endpoint)\n• Server: <code>${SERVER_NAME}</code>"
  elif [ "$error_rate" -gt 0 ]; then
    err_icon="${ICON_WARN}"
  else
    err_icon="${ICON_OK}"
  fi
  
  content+="\n📉 Error Rate: ${err_icon} <code>${error_rate}%</code> (${total_error}/${total_eps})"
  content+="\n⏱️ Avg Response: <code>${avg_ms}ms</code>"
  
  add_section "$content"
  print_ok
  log "Performance: errors=$total_error/$total_eps (${error_rate}%), avg=${avg_ms}ms"
}

# ─────────────────────────────────────────────
#  BUILD & SEND TELEGRAM MESSAGES
# ─────────────────────────────────────────────
send_full_report() {
  # Header
  local msg=""
  msg+="${ICON_REPORT} <b>VPS MONITORING REPORT</b>\n"
  msg+="━━━━━━━━━━━━━━━━━━━━━━━\n"
  msg+="${ICON_SERVER} <b>Server:</b> <code>${SERVER_NAME}</code>\n"
  msg+="🕐 <b>Waktu:</b> <code>${DATE_SHORT} WIB</code>\n"
  msg+="━━━━━━━━━━━━━━━━━━━━━━━\n\n"
  
  # Sections - gabungkan tapi jaga panjang pesan < 4096 char (limit Telegram)
  local current_msg="$msg"
  local section_count=0
  
  for section in "${REPORT_SECTIONS[@]}"; do
    local candidate="${current_msg}${section}\n\n"
    
    if [ ${#candidate} -gt 3800 ]; then
      # Kirim pesan saat ini, mulai yang baru
      send_telegram "$current_msg"
      sleep 1
      current_msg="${section}\n\n"
    else
      current_msg="${current_msg}${section}\n\n"
    fi
    (( section_count++ ))
  done
  
  # Footer
  current_msg+="━━━━━━━━━━━━━━━━━━━━━━━\n"
  if $ALERT_TRIGGERED; then
    current_msg+="🔴 Ada masalah terdeteksi! Cek alert di atas."
  else
    current_msg+="${ICON_OK} Semua sistem normal."
  fi
  
  send_telegram "$current_msg"
  log "Report dikirim (${section_count} sections)"
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
    log "Alert dikirim ke Telegram" "WARN"
  fi
}

# ─────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────
main() {
  local mode="${1:-full}"
  
  # ── Test mode ──
  if [ "$mode" = "test" ]; then
    echo "🔧 Mengirim test ke Telegram..."
    send_telegram "${ICON_OK} <b>TEST BERHASIL!</b>

${ICON_SERVER} Server: <code>${SERVER_NAME}</code>
🕐 Waktu: <code>${DATE_SHORT} WIB</code>

VPS Monitor sudah terhubung dan siap digunakan! 🚀"
    if [ $? -eq 0 ]; then
      echo "✅ Test message berhasil dikirim! Cek Telegram kamu."
    else
      echo "❌ Gagal kirim. Cek TELEGRAM_BOT_TOKEN dan TELEGRAM_CHAT_ID di monitor.conf"
    fi
    exit 0
  fi
  
  # ── Status mode (print ke terminal saja) ──
  if [ "$mode" = "status" ]; then
    echo "📊 Checking VPS status (no Telegram)..."
    TELEGRAM_BOT_TOKEN=""  # Disable telegram
  fi
  
  # Setup
  touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/vps_monitor.log"
  check_deps
  check_lock
  
  echo ""
  echo "=== 🖥️  VPS Monitor: ${SERVER_NAME} ==="
  echo "=== 🕐  ${TIMESTAMP} ==="
  echo ""
  
  log "=== Monitoring dimulai ==="
  
  # Jalankan semua check
  check_server_status
  check_endpoints
  check_ssl
  check_resources
  check_services
  check_performance
  
  echo ""
  echo "✅ Semua pengecekan selesai."
  echo ""
  
  # Kirim ke Telegram
  case "$mode" in
    alert|alert-only)
      send_alert_message
      ;;
    report|report-only)
      send_full_report
      ;;
    status)
      # Print sections ke terminal
      for s in "${REPORT_SECTIONS[@]}"; do
        echo -e "$s" | sed 's/<[^>]*>//g'
        echo "---"
      done
      ;;
    full|*)
      # Kirim alert dulu (prioritas)
      send_alert_message
      sleep 2
      # Lalu kirim full report
      send_full_report
      ;;
  esac
  
  log "=== Monitoring selesai ==="
  
  if $ALERT_TRIGGERED; then
    exit 1  # Ada masalah
  else
    exit 0  # Semua aman
  fi
}

main "$@"
