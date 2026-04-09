#!/bin/bash
# ─────────────────────────────────────────────
#  MODULE: SERVICE STATUS
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
