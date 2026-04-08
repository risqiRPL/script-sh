# 🖥️ VPS Monitor - Script Monitoring untuk Telegram

Script shell untuk memantau VPS secara otomatis dan mengirim notifikasi ke **Telegram Bot**.

---

## 📦 File Structure

```
script-sh/
├── vps_monitor.sh     ← Script utama monitoring
├── monitor.conf       ← File konfigurasi (edit ini!)
├── setup_monitor.sh   ← Wizard setup otomatis
└── README.md
```

---

## 🚀 Quick Start (Di VPS)

### Langkah 1 — Upload ke VPS
```bash
scp -r ./script-sh root@fezora.net:/opt/vps-monitor
```

### Langkah 2 — Jalankan Setup Wizard
```bash
cd /opt/vps-monitor
bash setup_monitor.sh
```

Wizard akan memandu:
- ✅ Install dependencies
- ✅ Konfigurasi Telegram token & chat ID
- ✅ Test koneksi Telegram
- ✅ Setup jadwal cron otomatis

---

## ⚙️ Konfigurasi Manual (`monitor.conf`)

Edit file `monitor.conf` sesuai kebutuhanmu:

```bash
# Telegram
TELEGRAM_BOT_TOKEN="1234567890:ABCxxxxxxxxxx"
TELEGRAM_CHAT_ID="-100123456789"   # Negatif = Group/Channel
SERVER_NAME="VPS-Production"

# Endpoint yang dipantau
ENDPOINTS=(
  "Website|https://fezora.net"
  "API|https://api.fezora.net"
)

# Service systemd yang dipantau
SERVICES=(
  "Nginx|nginx"
  "Docker|docker"
  "MySQL|mysql"
)

# Domain SSL yang dipantau
SSL_DOMAINS=(
  "fezora.net"
  "api.fezora.net"
)

# Threshold alert
CPU_THRESHOLD=80       # Alert jika CPU > 80%
RAM_THRESHOLD=85       # Alert jika RAM > 85%
DISK_THRESHOLD=85      # Alert jika Disk > 85%
SSL_WARN_DAYS=14       # Warning H-14 sebelum SSL expire
RESPONSE_WARN_MS=3000  # Warning jika response > 3000ms
```

---

## 📱 Cara Buat Telegram Bot

1. Chat [@BotFather](https://t.me/BotFather) di Telegram
2. Ketik `/newbot` → ikuti instruksi → dapat **Bot Token**
3. Invite bot ke group/channel kamu
4. Dapat Chat ID:
   ```
   https://api.telegram.org/bot<TOKEN>/getUpdates
   ```
   Cari nilai `"chat":{"id": -100xxxxxxx}`

---

## 🔧 Perintah

```bash
# Test kirim ke Telegram
bash vps_monitor.sh test

# Cek status, print ke terminal (no Telegram)
bash vps_monitor.sh status

# Hanya kirim ALERT jika ada masalah (untuk cron frequent)
bash vps_monitor.sh alert

# Hanya kirim full REPORT (untuk cron terjadwal)
bash vps_monitor.sh report

# Full check + kirim semua
bash vps_monitor.sh

# Gunakan config berbeda
bash vps_monitor.sh --config /path/to/other.conf
```

---

## ⏰ Setup Cron Manual

Edit crontab:
```bash
crontab -e
```

Contoh jadwal yang direkomendasikan:
```cron
# Alert check setiap 5 menit (hanya kirim jika ada masalah)
*/5 * * * * bash /opt/vps-monitor/vps_monitor.sh alert >> /var/log/vps_monitor.log 2>&1

# Full report setiap 30 menit
*/30 * * * * bash /opt/vps-monitor/vps_monitor.sh report >> /var/log/vps_monitor.log 2>&1

# Report harian jam 08.00 pagi
0 8 * * * bash /opt/vps-monitor/vps_monitor.sh report >> /var/log/vps_monitor.log 2>&1
```

---

## 📊 Apa yang Dipantau?

| Kategori | Detail |
|----------|--------|
| **Server Status** | Uptime, Internet, Load Average |
| **Endpoint** | HTTP status code, response time per URL |
| **SSL Certificate** | Sisa hari, tanggal expire, warning H-14 |
| **CPU** | Usage % dengan bar visualizer |
| **RAM** | Used/Total MB dengan bar visualizer |
| **Disk** | Usage per partisi dengan bar visualizer |
| **Services** | Status systemd (active/stopped/failed) |
| **Performance** | DNS/TCP/TTFB timing, error rate, avg response |
| **Network I/O** | RX/TX bytes per second |

---

## 📬 Contoh Notifikasi Telegram

### ✅ Normal Report
```
📊 VPS MONITORING REPORT
━━━━━━━━━━━━━━━━━━━━━━━
🖥️ Server: VPS-Fezora
🕐 Waktu: 08/04/2026 20:30 WIB
━━━━━━━━━━━━━━━━━━━━━━━

🖥️ SERVER STATUS
─────────────────
  ✅ Uptime: 15 days, 3 hours
  ℹ️ Internet: ✅ Online
  📈 Load: 0.45 | 0.38 | 0.31 (1m|5m|15m)

🌐 ENDPOINT STATUS
─────────────────
  • Website Utama: ✅ HTTP 200 (234ms)
  • Supabase DB2: ✅ HTTP 200 (312ms)

🔒 SSL CERTIFICATE
─────────────────
  • fezora.net: ✅ 87 hari
    📅 04 Jul 2026 🟢🟢🟢🟢🟢
```

### 🚨 Alert
```
🚨 ⚠️ VPS ALERT! ⚠️
━━━━━━━━━━━━━━━━━━━━━━━
🖥️ Server: VPS-Fezora
🕐 Waktu: 08/04/2026 20:30 WIB
━━━━━━━━━━━━━━━━━━━━━━━

🔴 DISK HAMPIR PENUH!
• Mount: /
• Used: 87% (210GB / 240GB)
• Sisa: 30GB
```

---

## 🐞 Troubleshooting

| Problem | Solusi |
|---------|--------|
| Telegram tidak dapat pesan | Cek token & chat_id, pastikan bot sudah di-invite ke group |
| SSL check gagal | Install `openssl`, pastikan port 443 bisa dihubungi |
| CPU tidak terdeteksi | Pastikan `/proc/stat` tersedia (Linux) |
| Service tidak ketemu | Cek nama service: `systemctl list-units --type=service` |
| Script error `bc: not found` | Install: `apt install bc -y` |

---

## 📝 Log

```bash
# Lihat log realtime
tail -f /var/log/vps_monitor.log

# Lihat log terakhir
tail -100 /var/log/vps_monitor.log

# Cari error
grep "ERROR\|WARN" /var/log/vps_monitor.log
```

---

## 📌 Multiple VPS

Untuk memantau banyak VPS, buat config terpisah di tiap server:

```bash
# VPS 1
bash vps_monitor.sh --config /opt/monitor-vps1.conf

# VPS 2
bash vps_monitor.sh --config /opt/monitor-vps2.conf
```

Notifikasi di Telegram akan menampilkan nama `SERVER_NAME` masing-masing.

---

*Made with ❤️ by risqiRPL*
