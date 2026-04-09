#!/bin/bash
# ─────────────────────────────────────────────
#  MODULE: PERFORMANCE (Speed & Error Rate)
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
}
