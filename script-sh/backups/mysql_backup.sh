#!/bin/bash
# ============================================================
#  MySQL Daily Backup — fezora.net (Optimized)
# ============================================================

# --- 5. KONFIGURASI TERPUSAT ---
if [ -f "$(dirname "$0")/backup.conf" ]; then source "$(dirname "$0")/backup.conf"; fi

# Default credentials (akan ditimpa jika ada di backup.conf)
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-613594704:AAGIgoPgUdIqX7v4tS8VHPdr2ewzNhsrrBQ}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:--1001491708403}"

# Default values if config not found
DB_USER="${DB_USER:-root}"
DB_PASS="${DB_PASS:-@Yahoo212}"
BACKUP_DIR="${BACKUP_DIR:-/root/backups/mysql}"
LOG_DIR="${LOG_DIR:-/root/backups/logs}"
DISK_THRESHOLD="${DISK_THRESHOLD:-90}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"

# --- INISIALISASI ---
TODAY=$(date +"%Y-%m-%d")
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")
LOG_FILE="${LOG_DIR}/mysql_${TODAY}.log"
mkdir -p "$BACKUP_DIR" "$LOG_DIR"

log() { echo -e "[$(date +'%H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

tg_msg() {
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=$1" \
        -d "parse_mode=HTML" > /dev/null 2>&1
}

tg_file() {
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
        -F "chat_id=${TELEGRAM_CHAT_ID}" \
        -F "document=@$1" \
        -F "caption=$2" \
        -F "parse_mode=HTML" > /dev/null 2>&1
}

log "===== MySQL Backup Harian — ${TODAY} ====="

# --- 3. CEK KAPASITAS DISK ---
DISK_USAGE=$(df -h / | grep / | tail -n 1 | awk '{ print $5 }' | sed 's/%//g')
if [ "$DISK_USAGE" -gt "$DISK_THRESHOLD" ]; then
    log "🚨 CRITICAL: Disk Usage ${DISK_USAGE}%! Melebihi threshold ${DISK_THRESHOLD}%."
    tg_msg "🚨 <b>CRITICAL: DISK FULL</b> on <code>fezora.net</code> (${DISK_USAGE}%)!
Backup MySQL dibatalkan untuk menjaga stabilitas server."
    exit 1
fi
log "  ℹ Disk Usage: ${DISK_USAGE}% (Threshold: ${DISK_THRESHOLD}%)"

# --- AMBIL DAFTAR DATABASE ---
DATABASES=$(mysql -u"$DB_USER" -p"$DB_PASS" -e "SHOW DATABASES;" 2>/dev/null \
    | grep -Ev "^(Database|information_schema|performance_schema|mysql|sys)$")

SUMMARY=()
COUNT_NEW=0
COUNT_SKIP=0
COUNT_FAIL=0

# --- PROSES TIAP DATABASE ---
for DB in $DATABASES; do
    DB_DIR="${BACKUP_DIR}/${DB}"
    mkdir -p "$DB_DIR"

    HASH_FILE="${DB_DIR}/.last_hash"
    TEMP_SQL="/tmp/mysql_${DB}_tmp.sql"
    BACKUP_FILE="${DB_DIR}/${DB}_${TIMESTAMP}.sql.gz"

    log "  ▶ Memproses: ${DB}"

    if ! mysqldump --skip-dump-date -u"$DB_USER" -p"$DB_PASS" "$DB" 2>>"$LOG_FILE" > "$TEMP_SQL"; then
        log "  ✗ Gagal dump: ${DB}"
        SUMMARY+=("❌ <b>${DB}</b>: Dump gagal")
        COUNT_FAIL=$((COUNT_FAIL + 1))
        rm -f "$TEMP_SQL"
        continue
    fi

    NEW_HASH=$(md5sum "$TEMP_SQL" | awk '{print $1}')
    OLD_HASH=$(cat "$HASH_FILE" 2>/dev/null || echo "")

    if [[ "$NEW_HASH" == "$OLD_HASH" ]]; then
        log "  ⏩ Tidak ada perubahan: ${DB}"
        SUMMARY+=("⏩ <b>${DB}</b>: Tidak ada perubahan")
        COUNT_SKIP=$((COUNT_SKIP + 1))
        rm -f "$TEMP_SQL"
        continue
    fi

    gzip -c "$TEMP_SQL" > "$BACKUP_FILE"
    rm -f "$TEMP_SQL"
    echo "$NEW_HASH" > "$HASH_FILE"

    SIZE=$(du -sh "$BACKUP_FILE" | awk '{print $1}')
    log "  ✓ Backup baru: ${DB} (${SIZE})"
    SUMMARY+=("💾 <b>${DB}</b>: ${SIZE}")
    COUNT_NEW=$((COUNT_NEW + 1))

    BYTES=$(stat -c%s "$BACKUP_FILE" 2>/dev/null)
    if [[ "${BYTES:-0}" -lt 52428800 ]]; then
        tg_file "$BACKUP_FILE" "🗄 <b>MySQL</b> | <code>${DB}</code> | ${TODAY}"
    else
        SUMMARY+=("   ⚠️ File >50MB, hanya notifikasi")
    fi
done

# --- HAPUS BACKUP LAMA ---
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +"$RETENTION_DAYS" -delete 2>>"$LOG_FILE"
log "  🧹 Backup lama (>${RETENTION_DAYS} hari) dibersihkan."

# --- 4. HAPUS LOG LAMA ---
find "$LOG_DIR" -name "*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>>"$LOG_FILE"
log "  🗑 Log lama (>${LOG_RETENTION_DAYS} hari) dibersihkan."

# --- KIRIM LAPORAN KE TELEGRAM ---
if [[ $COUNT_NEW -gt 0 ]]; then OVERALL="✅ Ada data baru"
elif [[ $COUNT_FAIL -gt 0 ]]; then OVERALL="⚠️ Ada kegagalan"
else OVERALL="⏩ Semua data tidak berubah"; fi

tg_msg "🗄 <b>Laporan Backup MySQL</b>
🖥 Server: fezora.net
📅 ${TODAY} | 🕐 $(date +'%H:%M')
${OVERALL}
━━━━━━━━━━━━━━━
$(printf '%s\n' "${SUMMARY[@]}")
━━━━━━━━━━━━━━━
💾 Baru: ${COUNT_NEW} | ⏩ Skip: ${COUNT_SKIP} | ❌ Gagal: ${COUNT_FAIL}
🗓 Retensi: ${RETENTION_DAYS} hari"

log "===== Selesai: ${OVERALL} ====="
