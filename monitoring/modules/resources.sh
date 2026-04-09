#!/bin/bash
# ─────────────────────────────────────────────
#  MODULE: RESOURCE USAGE (CPU, RAM, Disk)
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
