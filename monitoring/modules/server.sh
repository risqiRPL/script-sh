#!/bin/bash
# ─────────────────────────────────────────────
#  MODULE: SERVER STATUS
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
