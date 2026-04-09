#!/bin/bash
# ============================================================
#  Supabase Daily Backup — fezora.net (Optimized)
#  Backups: PostgreSQL (pg_dumpall), Edge Functions, Storage
# ============================================================

# --- 5. KONFIGURASI TERPUSAT ---
if [ -f /root/backup.conf ]; then source /root/backup.conf; fi

# Default values if config not found
DB_INSTANCES=("db1" "db2" "db3")
PG_USER="${PG_USER:-postgres}"
BACKUP_DIR="${BACKUP_DIR:-/root/backups/supabase}"
LOG_DIR="${LOG_DIR:-/root/backups/logs}"
DISK_THRESHOLD="${DISK_THRESHOLD:-90}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"

# --- INISIALISASI ---
TODAY=$(date +"%Y-%m-%d")
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")
LOG_FILE="${LOG_DIR}/supabase_${TODAY}.log"
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

log "===== Supabase Backup Harian — ${TODAY} ====="

# --- 3. CEK KAPASITAS DISK ---
DISK_USAGE=$(df -h / | grep / | tail -n 1 | awk '{ print $5 }' | sed 's/%//g')
if [ "$DISK_USAGE" -gt "$DISK_THRESHOLD" ]; then
    log "🚨 CRITICAL: Disk Usage ${DISK_USAGE}%! Melebihi threshold ${DISK_THRESHOLD}%."
    tg_msg "🚨 <b>CRITICAL: DISK FULL</b> on <code>fezora.net</code> (${DISK_USAGE}%)!
Backup Supabase dibatalkan untuk menjaga stabilitas server."
    exit 1
fi
log "  ℹ Disk Usage: ${DISK_USAGE}% (Threshold: ${DISK_THRESHOLD}%)"

SUMMARY=()
COUNT_NEW=0
COUNT_SKIP=0
COUNT_FAIL=0

# --- PROSES TIAP INSTANCE ---
for DB_ID in "${DB_INSTANCES[@]}"; do
    DB_DIR="${BACKUP_DIR}/${DB_ID}"
    mkdir -p "$DB_DIR"

    HASH_FILE="${DB_DIR}/.last_hash"
    TEMP_SQL="/tmp/supabase_${DB_ID}_tmp.sql"
    BACKUP_FILE="${DB_DIR}/${DB_ID}_${TIMESTAMP}.sql.gz"

    log "  ▶ Memproses: ${DB_ID}"

    CONTAINER_PREFIX="${DB_ID}-db"
    CONTAINER=$(docker ps --format '{{.Names}}' | grep "^${CONTAINER_PREFIX}" | head -n 1)
    
    if [[ -z "$CONTAINER" ]]; then
        log "  ✗ Container ${DB_ID} tidak ditemukan (Offline?)"
        SUMMARY+=("❌ <b>${DB_ID}</b>: Container offline")
        COUNT_FAIL=$((COUNT_FAIL + 1))
        continue
    fi

    if ! docker exec -i "$CONTAINER" pg_dumpall -U "$PG_USER" > "$TEMP_SQL" 2>>"$LOG_FILE"; then
        log "  ✗ Gagal dump: ${DB_ID}"
        SUMMARY+=("❌ <b>${DB_ID}</b>: Dump gagal")
        COUNT_FAIL=$((COUNT_FAIL + 1))
        rm -f "$TEMP_SQL"
        continue
    fi

    NEW_HASH=$(md5sum "$TEMP_SQL" | awk '{print $1}')
    OLD_HASH=$(cat "$HASH_FILE" 2>/dev/null || echo "")

    if [[ "$NEW_HASH" == "$OLD_HASH" ]]; then
        log "  ⏩ Tidak ada perubahan DB: ${DB_ID}"
        SUMMARY+=("⏩ <b>${DB_ID} (DB)</b>: Tidak ada perubahan")
        COUNT_SKIP=$((COUNT_SKIP + 1))
        rm -f "$TEMP_SQL"
    else
        gzip -c "$TEMP_SQL" > "$BACKUP_FILE"
        rm -f "$TEMP_SQL"
        echo "$NEW_HASH" > "$HASH_FILE"

        SIZE=$(du -sh "$BACKUP_FILE" | awk '{print $1}')
        log "  ✓ Backup DB baru: ${DB_ID} (${SIZE})"
        SUMMARY+=("💾 <b>${DB_ID} (DB)</b>: ${SIZE}")
        COUNT_NEW=$((COUNT_NEW + 1))

        BYTES=$(stat -c%s "$BACKUP_FILE" 2>/dev/null)
        if [[ "${BYTES:-0}" -lt 52428800 ]]; then
            tg_file "$BACKUP_FILE" "🐘 <b>DB Backup</b> | <code>${DB_ID}</code> | ${TODAY}"
        else
            SUMMARY+=("   ⚠️ DB >50MB, hanya notifikasi")
        fi
    fi

    # Backup Edge Functions & Secrets (.env)
    VPS_DOCKER_DIR="/home/supabase/domains/${DB_ID}.supabase.fezora.net/docker"
    VPS_FUNCTIONS_DIR="${VPS_DOCKER_DIR}/volumes/functions"
    FUNC_BACKUP_FILE="${DB_DIR}/${DB_ID}_functions_${TIMESTAMP}.tar.gz"

    if [ -d "$VPS_FUNCTIONS_DIR" ]; then
        log "  ▶ Mem-backup Functions & Secrets: ${DB_ID}"
        tar -czf "$FUNC_BACKUP_FILE" -C "$VPS_DOCKER_DIR/volumes" functions 2>>"$LOG_FILE"
        SIZE_FUNC=$(du -sh "$FUNC_BACKUP_FILE" | awk '{print $1}')
        SUMMARY+=("📦 <b>${DB_ID} (Func)</b>: ${SIZE_FUNC}")
        
        BYTES_FUNC=$(stat -c%s "$FUNC_BACKUP_FILE" 2>/dev/null)
        if [[ "${BYTES_FUNC:-0}" -lt 52428800 ]]; then
            tg_file "$FUNC_BACKUP_FILE" "⚡ <b>Functions & Secrets</b> | <code>${DB_ID}</code> | ${TODAY}"
        else
            SUMMARY+=("   ⚠️ Func >50MB (tidak dikirim)")
        fi
    fi

    # Backup Storage Files
    VPS_STORAGE_DIR="${VPS_DOCKER_DIR}/volumes/storage"
    STORAGE_BACKUP_FILE="${DB_DIR}/${DB_ID}_storage_${TIMESTAMP}.tar.gz"

    if [ -d "$VPS_STORAGE_DIR" ]; then
        log "  ▶ Mem-backup Storage Files: ${DB_ID}"
        tar -czf "$STORAGE_BACKUP_FILE" -C "$VPS_DOCKER_DIR/volumes" storage 2>>"$LOG_FILE"
        SIZE_STORAGE=$(du -sh "$STORAGE_BACKUP_FILE" | awk '{print $1}')
        SUMMARY+=("🗂 <b>${DB_ID} (Storage)</b>: ${SIZE_STORAGE}")
        
        BYTES_STORAGE=$(stat -c%s "$STORAGE_BACKUP_FILE" 2>/dev/null)
        if [[ "${BYTES_STORAGE:-0}" -lt 52428800 ]]; then
            tg_file "$STORAGE_BACKUP_FILE" "🗂 <b>Storage Files</b> | <code>${DB_ID}</code> | ${TODAY}"
        else
            SUMMARY+=("   ⚠️ Storage >50MB (tidak dikirim)")
        fi
    fi

done

# --- HAPUS BACKUP LAMA ---
find "$BACKUP_DIR" -type f \( -name "*.sql.gz" -o -name "*.tar.gz" \) -mtime +"$RETENTION_DAYS" -delete 2>>"$LOG_FILE"
log "  🗑 Backup lama (>${RETENTION_DAYS} hari) dibersihkan."

# --- 4. HAPUS LOG LAMA ---
find "$LOG_DIR" -name "*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>>"$LOG_FILE"
log "  🗑 Log lama (>${LOG_RETENTION_DAYS} hari) dibersihkan."

# --- KIRIM LAPORAN KE TELEGRAM ---
if [[ $COUNT_NEW -gt 0 ]]; then OVERALL="✅ Ada data baru"
elif [[ $COUNT_FAIL -gt 0 ]]; then OVERALL="⚠️ Ada kegagalan"
else OVERALL="⏩ Semua data tidak berubah"; fi

tg_msg "🐘 <b>Laporan Backup Supabase</b>
🖥 Server: fezora.net
📅 ${TODAY} | 🕐 $(date +'%H:%M')
${OVERALL}
━━━━━━━━━━━━━━━
$(printf '%s\n' "${SUMMARY[@]}")
━━━━━━━━━━━━━━━
💾 Baru: ${COUNT_NEW} | ⏩ Skip: ${COUNT_SKIP} | ❌ Gagal: ${COUNT_FAIL}
🗓 Retensi: ${RETENTION_DAYS} hari"

log "===== Selesai: ${OVERALL} ====="
