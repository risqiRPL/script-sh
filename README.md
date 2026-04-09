# 🚀 Fezora Server Management Scripts

Kumpulan script otomatisasi untuk manajemen VPS, backup database, dan monitoring sistem pada server Fezora.

## 📂 Struktur Folder
- `backups/`: Script backup harian untuk MySQL dan Supabase (Docker).
- `database/`: Script utilitas database (migrasi, dsb).
- `monitoring/`: Sistem monitoring VPS modular dengan notifikasi Telegram.
- `wa-bot/`: Bot WhatsApp Node.js untuk layanan notifikasi.
- `crontab.txt`: Dokumentasi jadwal tugas otomatis (cron job).

## 🛠 Instalasi & Penggunaan

### 1. Monitoring
Masuk ke folder `monitoring` dan jalankan script setup:
```bash
cd monitoring
bash setup_monitor.sh
```
Ikuti wizard untuk memasukkan Token Telegram dan mengatur jadwal.

### 2. Backup Database
Pastikan file `/root/backup.conf` sudah dikonfigurasi dengan:
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CHAT_ID`
- `RETENTION_DAYS` (hari penyimpanan file backup)

Jalankan backup manual jika diperlukan:
```bash
bash backups/mysql_backup.sh
bash backups/supabase_backup.sh
```

### 3. Otomasi (Cron Job)
Gunakan perintah `crontab -e` dan salin isi dari `crontab.txt` untuk mengaktifkan semua jadwal otomatis.

## 📝 Catatan
- Semua log backup akan disimpan di `/root/backups/logs/`.
- File backup otomatis dikirim ke Telegram jika ukuran < 50MB.

---
**Maintained by risqiRPL**