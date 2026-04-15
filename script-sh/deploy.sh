#!/bin/bash

# ============================================================
#  FEZORA VPS DEPLOYMENT SCRIPT
#  Gunakan script ini untuk sinkronisasi lokal ke VPS.
# ============================================================

# --- 1. CONFIGURATION ---
REMOTE_USER="root"
REMOTE_HOST="fezora.net"
REMOTE_DEST="/root/script-sh/"

# --- 2. SYNC FILES ---
echo "🚀 Memulai deployment ke ${REMOTE_HOST}..."
rsync -avz --delete \
    --exclude '.git' \
    --exclude '.DS_Store' \
    --exclude 'node_modules' \
    --exclude 'monitoring/state.json' \
    . "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DEST}"

if [ $? -eq 0 ]; then
    echo "✅ Sinkronisasi file berhasil."
else
    echo "❌ Sinkronisasi file gagal."
    exit 1
fi

# --- 3. REMOTE ACTIVATION ---
echo "⚙️ Menjalankan perintah remote di VPS..."
ssh "${REMOTE_USER}@${REMOTE_HOST}" "
    # Update Monitoring
    cd ${REMOTE_DEST}monitoring && npm install && pm2 restart vps-monitor || pm2 start monitor.mjs --name vps-monitor
    
    # Update WA-Bot
    cd ${REMOTE_DEST}wa-bot && npm install && pm2 restart wa-bot || pm2 start run_wa_bot.mjs --name wa-bot
    
    # Update Crontab
    cd ${REMOTE_DEST} && crontab crontab.txt
    
    # Save PM2 State
    pm2 save
"

echo "✨ Deployment Selesai! Semua sistem aktif dan sinkron."
