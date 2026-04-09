#!/bin/bash
# ─────────────────────────────────────────────
#  MODULE: ENDPOINT STATUS
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
