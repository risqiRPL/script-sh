#!/bin/bash
# ─────────────────────────────────────────────
#  MODULE: SSL CERTIFICATE CHECK
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
