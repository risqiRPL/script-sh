#!/bin/bash

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  POSTGRESQL PROFESSIONAL BACKUP & TELEGRAM NOTIFIER
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Database: presensi
# Author: Gemini CLI
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ── 1. CONFIGURATION ──
if [ -f "$(dirname "$0")/backup.conf" ]; then source "$(dirname "$0")/backup.conf"; fi

DB_NAME="presensi"
DB_USER="${DB_USER:-root}"
DB_PASS="${DB_PASS:-@Yahoo212}"
DB_HOST="localhost"
DB_PORT="5432"

# Paths
BACKUP_DIR="/root/script-sh/backups/files/postgre"
LOG_FILE="/root/script-sh/backups/logs/postgre_backup.log"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")
FILE_NAME="backup_${DB_NAME}_${DATE}.sql.gz"
BACKUP_PATH="${BACKUP_DIR}/${FILE_NAME}"

# Telegram Settings
TOKEN="${TELEGRAM_BOT_TOKEN:-613594704:AAGOatk_xKZrTqL5bpryZOdK-Q0Dc5FvSUA}"
CHAT_ID="${TELEGRAM_CHAT_ID:--1001491708403}"

# ── 2. START PROCESS ──
echo "[$(date)] INFO: Starting backup for database: ${DB_NAME}" >> $LOG_FILE

# Ensure directory exists
mkdir -p $BACKUP_DIR

# ── 3. EXECUTE DUMP ──
export PGPASSWORD="${DB_PASS}"
pg_dump -h $DB_HOST -p $DB_PORT -U $DB_USER $DB_NAME | gzip > $BACKUP_PATH

if [ $? -eq 0 ]; then
    SIZE=$(du -sh $BACKUP_PATH | awk '{print $1}')
    echo "[$(date)] SUCCESS: Backup created at ${BACKUP_PATH} (${SIZE})" >> $LOG_FILE
    
    # ── 4. TELEGRAM NOTIFICATION ──
    CAPTION="🐘 <b>PostgreSQL Backup</b> | <code>${DB_NAME}</code> | $(date +'%Y-%m-%d %H:%M')"
    
    RESPONSE=$(curl -s -F chat_id="$CHAT_ID" -F document=@"$BACKUP_PATH" -F caption="$CAPTION" -F parse_mode="HTML" https://api.telegram.org/bot$TOKEN/sendDocument)
    
    if [[ $RESPONSE == *"\"ok\":true"* ]]; then
        echo "[$(date)] INFO: Backup file sent to Telegram." >> $LOG_FILE
    else
        echo "[$(date)] ERROR: Failed to send to Telegram. Response: $RESPONSE" >> $LOG_FILE
    fi
    
    # ── 5. CLEANUP (Keep 7 days) ──
    find $BACKUP_DIR -name "*.sql.gz" -mtime +7 -delete
    echo "[$(date)] INFO: Old backups cleaned up." >> $LOG_FILE
else
    echo "[$(date)] CRITICAL: Backup FAILED for ${DB_NAME}!" >> $LOG_FILE
    # Notify Failure to Telegram
    ERROR_MSG="⚠️ <b>CRITICAL: PostgreSQL Backup FAILED</b>%0A❌ Database: <code>${DB_NAME}</code>%0A📅 Date: <code>$(date +'%Y-%m-%d %H:%M')</code>%0A🖥️ Host: <code>31.97.108.71</code>"
    curl -s -X POST https://api.telegram.org/bot$TOKEN/sendMessage -d chat_id="$CHAT_ID" -d text="$ERROR_MSG" -d parse_mode="HTML"
fi

unset PGPASSWORD
echo "[$(date)] INFO: Process finished." >> $LOG_FILE
echo "--------------------------------------------------" >> $LOG_FILE
