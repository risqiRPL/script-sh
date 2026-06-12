#!/bin/bash

# ============================================================
#  FEZORA VPS DEPLOYMENT SCRIPT
#  Sinkronisasi script-sh lokal ke VPS.
# ============================================================

REMOTE_USER="root"
REMOTE_HOST="fezora.net"
REMOTE_DEST="/root/script-sh/"

echo "🚀 Memulai deployment ke ${REMOTE_HOST}..."
rsync -avz --delete \
    --exclude '.git' \
    --exclude '.DS_Store' \
    --exclude 'node_modules' \
    . "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DEST}"

if [ $? -ne 0 ]; then
    echo "❌ Sinkronisasi file gagal."
    exit 1
fi
echo "✅ Sinkronisasi file berhasil."

echo "⚙️ Menjalankan perintah remote..."
ssh "${REMOTE_USER}@${REMOTE_HOST}" "
    # WA-Bot
    cd ${REMOTE_DEST}wa-bot && npm install && (pm2 restart wa-bot || pm2 start run_wa_bot.mjs --name wa-bot)

    # Update Crontab
    cd ${REMOTE_DEST} && crontab crontab.txt

    # Save PM2
    pm2 save
"

echo "✨ Deployment selesai."
