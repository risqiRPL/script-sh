#!/bin/bash

# ==========================================
#      Supabase Migration Tool (v6.1)
#      Flow: Cloud -> Local -> VPS (Ultimate)
# ==========================================

# Cloud Settings (Supabase Dashboard)
CLOUD_PROJECT_REF="phaqqnqticnmcabjgzui"
CLOUD_ACCESS_TOKEN="sbp_9f7a699a11b1d044d039ca57df26c6ea448fef73"
CLOUD_DB_PASSWORD="w9rXMSaqb8ENsRuv"

# S3 Credentials (For Incremental Pull with Rclone)
S3_ACCESS_KEY_ID="0a550864e3ec8618f1dcd2ae4b155a2f"
S3_SECRET_ACCESS_KEY="70e60f969ce2facc219248eff427d0c408446c7130dc0e0289851b197a371184"
S3_REGION="ap-south-1"
S3_ENDPOINT="https://phaqqnqticnmcabjgzui.supabase.co/storage/v1/s3"



# Logging & Error Handling
SET_E=true
LOG_FILE="migration.log"

# --- SYSTEM SETUP ---
set -e
set -o pipefail

# Reset log if needed (Opsional: hapus baris ini jika ingin terus append)
# > "$LOG_FILE"

function log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

trap 'log "❌ ERROR: Skrip terhenti secara tidak terduga pada baris $LINENO"; exit 1' ERR


# App Secrets (Optional: for Notifications & Emails)
ONESIGNAL_API_KEY="GANTI_NILAI_INI_JIKA_ADA"
RESEND_API_KEY="GANTI_NILAI_INI_JIKA_ADA"

# VPS Settings
PROJECT_ID="db1"
SERVER_IP="31.97.108.71"
REMOTE_USER="root"

# Project Structure
BACKUP_DIR="supabase/backups"
STORAGE_DIR="supabase/storage"

SCHEMA_FILE="${BACKUP_DIR}/schema.sql"
DATA_FILE="${BACKUP_DIR}/data.sql"
REMOTE_PATH="/home/supabase/domains/${PROJECT_ID}.supabase.fezora.net/docker"

# Environmental Export
export SUPABASE_ACCESS_TOKEN="$CLOUD_ACCESS_TOKEN"

# Stats Initializer
CLOUD_TABLES="?"
CLOUD_ROWS="?"




log "=========================================="
log "      Supabase Migration Tool (v6.1)"
log "      Status: ULTIMATE MIGRATION"
log "=========================================="


function show_usage() {
    echo "Usage: ./migrate.sh [options]"
    echo "Options:"
    echo "  --pull    Pull DB, Functions & Storage from Cloud"
    echo "  --push    Push All Assets (including Secrets) to VPS"
    echo "  --all     Run Pull and then Push (Full Migration)"
    exit 1
}

# --- 1. PULL FROM CLOUD ---
function pull_from_cloud() {
    log "📥 Starting PULL from Supabase Cloud..."
    mkdir -p "$BACKUP_DIR" "$STORAGE_DIR"
    
    # 0. Link
    log "🔗 Linking to Cloud Project..."
    supabase link --project-ref "$CLOUD_PROJECT_REF" --password "$CLOUD_DB_PASSWORD"
    
    # 1. Gather Cloud Stats for Validation
    log "📊 Gathering Cloud Database Stats..."
    CLOUD_TABLES=$(supabase db query "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'" --linked --output json | tail -n 1 | grep -o '[0-9]\+' | head -n 1) || CLOUD_TABLES="?"
    CLOUD_ROWS=$(supabase db query "SELECT sum(n_live_tup) FROM pg_stat_user_tables WHERE schemaname = 'public'" --linked --output json | tail -n 1 | grep -o '[0-9]\+' | head -n 1) || CLOUD_ROWS="?"

    log "   -> Cloud Stats: $CLOUD_TABLES Tables, $CLOUD_ROWS Rows"

    # 1. Database
    log "⏳ Dumping Database (Schema & Data)..."
    supabase db dump -f "$SCHEMA_FILE"
    supabase db dump --data-only -f "$DATA_FILE"
    
    # 1.5 Compatibility Patch (transaction_timeout & other cloud-specifics)
    log "🩹 Patching SQL for VPS compatibility..."
    sed -i '' '/SET transaction_timeout/d' "$SCHEMA_FILE" "$DATA_FILE" || true
    sed -i '' '/unrecognized configuration parameter "transaction_timeout"/d' "$SCHEMA_FILE" "$DATA_FILE" || true

    # 2. Edge Functions

    log "⏳ Pulling Edge Functions..."
    FUNCTIONS=$(supabase functions list --project-ref "$CLOUD_PROJECT_REF" --output json | grep -o '"name": "[^"]*' | cut -d'"' -f4)
    for func in $FUNCTIONS; do
        log "   ▶ Downloading Function: $func"
        supabase functions download "$func" --project-ref "$CLOUD_PROJECT_REF"
    done
    
    # 3. Storage Buckets (Incremental Sync)
    log "⏳ Syncing Storage Buckets incrementally..."
    if command -v rclone >/dev/null 2>&1 && [[ -n "$S3_ACCESS_KEY_ID" && "$S3_ACCESS_KEY_ID" != "GANTI_DENGAN_*" ]]; then
        export RCLONE_CONFIG_SUPA_TYPE=s3
        export RCLONE_CONFIG_SUPA_PROVIDER=Other
        export RCLONE_CONFIG_SUPA_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
        export RCLONE_CONFIG_SUPA_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
        export RCLONE_CONFIG_SUPA_ENDPOINT="$S3_ENDPOINT"
        export RCLONE_CONFIG_SUPA_REGION="$S3_REGION"
        export RCLONE_CONFIG_SUPA_FORCE_PATH_STYLE=true
        
        rclone sync supa:/ "$STORAGE_DIR/" --progress --create-empty-src-dirs -vv

    else
        log "   ⚠️  Rclone not found or S3 credentials missing. Falling back to dynamic pull..."
        BUCKETS=$(supabase storage ls --experimental | grep '/' | sed 's/\///')
        for bucket in $BUCKETS; do
            log "   ▶ Pulling Bucket: $bucket"
            mkdir -p "${STORAGE_DIR}/${bucket}"
            supabase storage cp -r "ss:///${bucket}" "${STORAGE_DIR}/" --experimental || log "   ⚠️  Bucket $bucket maybe empty."
        done
    fi

    
    log "✅ PULL Complete!"
}


# --- 2. PUSH TO VPS ---
function push_to_vps() {
    log "🚀 Starting PUSH to VPS ($SERVER_IP)..."

    # 0. Safety Check
    log "🛡 Checking Backup Integrity..."
    if [[ ! -s "$SCHEMA_FILE" ]]; then log "❌ ERROR: Schema file is missing or empty!"; exit 1; fi
    if [[ ! -s "$DATA_FILE" ]]; then log "⚠️ WARNING: Data file is empty, proceed with caution."; fi
    
    # 1. Sync SQL
    log "📦 Syncing SQL Backups..."
    ssh "${REMOTE_USER}@${SERVER_IP}" "mkdir -p ${REMOTE_PATH}/backups"
    rsync -avz --progress "${BACKUP_DIR}/" "${REMOTE_USER}@${SERVER_IP}:${REMOTE_PATH}/backups/"

    # 2. Sync Edge Functions
    log "📦 Syncing Edge Functions..."
    rsync -avz --progress "supabase/functions/" "${REMOTE_USER}@${SERVER_IP}:${REMOTE_PATH}/volumes/functions/"

    # 3. Sync Storage
    log "📦 Syncing Storage Files..."
    ssh "${REMOTE_USER}@${SERVER_IP}" "mkdir -p ${REMOTE_PATH}/volumes/storage"
    rsync -avz --progress "${STORAGE_DIR}/" "${REMOTE_USER}@${SERVER_IP}:${REMOTE_PATH}/volumes/storage/"

    # 4. Generate Secrets on VPS (New in v6.2)
    log "🔐 Generating .env file on VPS..."
    ssh "${REMOTE_USER}@${SERVER_IP}" "cat << 'EOF' > ${REMOTE_PATH}/volumes/functions/.env
# Generated by migrate.sh
ONESIGNAL_API_KEY=\"$ONESIGNAL_API_KEY\"
RESEND_API_KEY=\"$RESEND_API_KEY\"
EOF"


    # Identify Container
    CONTAINER_NAME=$(ssh "${REMOTE_USER}@${SERVER_IP}" "docker ps --format '{{.Names}}' | grep '^${PROJECT_ID}-db' | head -n 1")
    if [ -z "$CONTAINER_NAME" ]; then CONTAINER_NAME="${PROJECT_ID}-db-1"; fi

    # Execute remote database import
    log "🧹 Cleaning schemas (public, auth, storage) & Importing data..."
    ssh "${REMOTE_USER}@${SERVER_IP}" "docker exec -i $CONTAINER_NAME psql -U postgres" << 'EOF'
DO $$ 
DECLARE r RECORD; 
BEGIN 
    SET session_replication_role = 'replica'; 
    -- Clean public schema
    FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP 
        EXECUTE 'DROP TABLE IF EXISTS public.' || quote_ident(r.tablename) || ' CASCADE;'; 
    END LOOP; 
    -- Clean auth & storage data
    FOR r IN (SELECT schemaname, tablename FROM pg_tables WHERE schemaname IN ('auth', 'storage')) LOOP 
        EXECUTE 'TRUNCATE TABLE ' || quote_ident(r.schemaname) || '.' || quote_ident(r.tablename) || ' CASCADE;'; 
    END LOOP; 
    -- Clean public types
    FOR r IN (SELECT t.typname FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = 'public' AND t.typtype = 'e') LOOP 
        EXECUTE 'DROP TYPE IF EXISTS public.' || quote_ident(r.typname) || ' CASCADE;'; 
    END LOOP; 
    SET session_replication_role = 'origin'; 
END $$;
EOF
    ssh "${REMOTE_USER}@${SERVER_IP}" "cat ${REMOTE_PATH}/backups/schema.sql | docker exec -i $CONTAINER_NAME psql -U postgres" > /dev/null
    ssh "${REMOTE_USER}@${SERVER_IP}" "cat ${REMOTE_PATH}/backups/data.sql | docker exec -i $CONTAINER_NAME psql -U postgres" > /dev/null


    # Sync Storage Physical Format (S3 -> Local Self-Hosted Backend)
    # Re-map rclone exported literal paths to UUID paths and fix extended metadata
    log "🛠 Restructuring Local Storage mapping (applying UUIDs & xattrs)..."
    ssh "${REMOTE_USER}@${SERVER_IP}" "cat << 'EOF' > ${REMOTE_PATH}/volumes/storage/fix_storage.py
import os
import subprocess
import json

project_id = \"$PROJECT_ID\"
container_name = \"$CONTAINER_NAME\"
storage_dir = \"${REMOTE_PATH}/volumes/storage\"

print(f\"Extracting metadata from DB for {project_id}...\")
cmd = f\"docker exec -i {container_name} psql -U postgres -d postgres -t -A -c \\\"SELECT bucket_id, name, version, metadata FROM storage.objects WHERE version IS NOT NULL;\\\"\"
try:
    output = subprocess.check_output(cmd, shell=True).decode('utf-8').strip()
except Exception as e:
    print('No storage objects or error:', e)
    output = ''

lines = [L for L in output.split('\n') if L.strip()]
print(f\"Found {len(lines)} file objects mapped in database.\")
count_migrated, count_xattr = 0, 0

for line in lines:
    parts = line.split('|', 3)
    if len(parts) != 4: continue
    bucket_id, name, version, metadata_str = parts
    
    src = f\"{storage_dir}/{bucket_id}/{name}\"
    tgt_dir = f\"{storage_dir}/stub/stub/{bucket_id}/{name}\"
    tgt_file = f\"{tgt_dir}/{version}\"
    
    # 1. Structure conversion (from Literal string folder to UUID filename)
    if os.path.exists(src):
        os.makedirs(tgt_dir, exist_ok=True)
        os.rename(src, tgt_file)
        count_migrated += 1
        
    # 2. Assigning NextJS / Supabase Storage Extended Attributes headers natively
    if os.path.exists(tgt_file):
        try:
            metadata = json.loads(metadata_str)
        except:
            metadata = {}
        mimetype = metadata.get('mimetype', 'application/octet-stream')
        cache_control = metadata.get('cacheControl', 'max-age=3600')
        
        try:
            os.setxattr(tgt_file, 'user.supabase.content-type', mimetype.encode('utf-8'))
            os.setxattr(tgt_file, 'user.supabase.cache-control', cache_control.encode('utf-8'))
            count_xattr += 1
        except Exception as e:
            pass

subprocess.call(f\"chown -R 1000:1000 {storage_dir}/stub 2>/dev/null\", shell=True)
print(f\"Successfully re-mapped {count_migrated} files and patched {count_xattr} xattrs!\")
EOF"
    ssh "${REMOTE_USER}@${SERVER_IP}" "python3 ${REMOTE_PATH}/volumes/storage/fix_storage.py" > /dev/null


    # Restart Functions container to pick up new secrets
    log "🔄 Refreshing Edge Functions Runtime..."
    ssh "${REMOTE_USER}@${SERVER_IP}" "docker restart ${PROJECT_ID}-functions-1" > /dev/null

    # Final Validation
    log "🏁 Running Post-Import Validation..."
    REMOTE_TABLES=$(ssh "${REMOTE_USER}@${SERVER_IP}" "docker exec -i $CONTAINER_NAME psql -U postgres -t -A -c \"SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';\"")
    REMOTE_ROWS=$(ssh "${REMOTE_USER}@${SERVER_IP}" "docker exec -i $CONTAINER_NAME psql -U postgres -t -A -c \"SELECT sum(n_live_tup) FROM pg_stat_user_tables WHERE schemaname = 'public';\"")
    
    # Validation logic for MATCH/DIFF
    STATUS_TABLES="⚠️ DIFF"
    if [[ "$CLOUD_TABLES" != "?" && "$REMOTE_TABLES" -eq "$CLOUD_TABLES" ]]; then STATUS_TABLES="✅ MATCH"; fi
    if [[ "$CLOUD_TABLES" == "?" ]]; then STATUS_TABLES="⚪ SKIP"; fi

    STATUS_ROWS="⚠️ DIFF"
    if [[ "$CLOUD_ROWS" != "?" && "$REMOTE_ROWS" -eq "$CLOUD_ROWS" ]]; then STATUS_ROWS="✅ MATCH"; fi
    if [[ "$CLOUD_ROWS" == "?" ]]; then STATUS_ROWS="⚪ SKIP"; fi

    log "------------------------------------------"
    log "📈 FINAL SUMMARY ($PROJECT_ID)"
    log "------------------------------------------"
    log "Component   | Cloud (Src) | VPS Result | Status"
    log "------------|-------------|------------|--------"
    printf "Tables      | %-11s | %-10s | %s\n" "$CLOUD_TABLES" "$REMOTE_TABLES" "$STATUS_TABLES" | tee -a "$LOG_FILE"
    printf "Total Rows  | %-11s | %-10s | %s\n" "$CLOUD_ROWS" "$REMOTE_ROWS" "$STATUS_ROWS" | tee -a "$LOG_FILE"

    log "------------------------------------------"
    
    log "🌟 Migration v6.1 Finished Successfully!"
}


# --- Argument Parsing ---
case "$1" in
    --pull) pull_from_cloud ;;
    --push) push_to_vps ;;
    --all) pull_from_cloud; push_to_vps ;;
    *) show_usage ;;
esac
