import fs from 'fs';
import { execSync } from 'child_process';
import fetch from 'node-fetch';
import path from 'path';

// --- INITIAL CONFIG ---
const CONFIG_PATH = './config.json';
const STATE_PATH = './state.json';
let config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf-8'));

// State storage (RAM + File persistence)
let state = {
    endpoints: {},
    services: {},
    wa_devices: {},
    wa_server_up: true,
    resources: {
        cpu:  { last_alert: 0, is_high: false, consecutive_high: 0 },
        ram:  { last_alert: 0, is_high: false },
        disk: { last_alert: 0, is_high: false }
    },
    pm2_restarts: {},
    ssl_cache: {},
    ssl_alerts: {},
    last_ssl_check: null,
    last_daily_report: null
};

if (fs.existsSync(STATE_PATH)) {
    try {
        const savedState = JSON.parse(fs.readFileSync(STATE_PATH, 'utf-8'));
        state = { ...state, ...savedState };
    } catch (e) {
        console.error("Error loading state.json, starting fresh.");
    }
}

function saveState() {
    fs.writeFileSync(STATE_PATH, JSON.stringify(state, null, 2));
}

// --- UTILITIES ---
function log(msg) {
    const timestamp = new Date().toLocaleString('id-ID');
    const line = `[${timestamp}] ${msg}`;
    console.log(line);
    try {
        fs.appendFileSync(config.LOG_FILE, line + '\n');
    } catch (e) {}
}

async function sendTelegram(message) {
    const url = `https://api.telegram.org/bot${config.TELEGRAM_BOT_TOKEN}/sendMessage`;
    try {
        await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                chat_id: config.TELEGRAM_CHAT_ID,
                text: message,
                parse_mode: 'HTML'
            })
        });
    } catch (e) {
        log(`❌ Telegram Error: ${e.message}`);
    }
}

// --- CHECKERS ---

// WhatsApp Bot Monitor
async function checkWhatsApp() {
    if (!config.WA_API) return;
    log('📱 Checking WhatsApp Devices...');

    let devices;
    try {
        const res = await fetch(config.WA_API.url + '/api/devices', { timeout: 8000 });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const json = await res.json();
        devices = json.data;

        if (!state.wa_server_up) {
            sendTelegram(`✅ <b>BOT WHATSAPP ONLINE KEMBALI</b>\n\n<b>Server:</b> ${config.WA_API.name}\n<b>Status:</b> API merespons normal`);
            state.wa_server_up = true;
        }
    } catch (e) {
        if (state.wa_server_up !== false) {
            sendTelegram(`🔴 <b>BOT WHATSAPP MATI</b>\n\n<b>Server:</b> ${config.WA_API.name}\n<b>Error:</b> ${e.message}\n<b>Aksi:</b> Cek PM2 / robot-wa.js`);
            log(`🔴 WA Server down: ${e.message}`);
            state.wa_server_up = false;
        }
        return;
    }

    for (const device of devices) {
        if (config.WA_API.ignore_devices && config.WA_API.ignore_devices.includes(device.id)) continue;

        const prev = state.wa_devices[device.id];
        const curr = device.status;
        const label = `<b>${device.name}</b> (${device.number || device.id})`;

        if (!prev) {
            if (curr === 'ready') {
                sendTelegram(`🟢 <b>DEVICE WA BARU TERHUBUNG</b>\n\n📱 Device: ${label}\n✅ Status: Siap digunakan`);
                log(`🟢 WA Device baru: ${device.name}`);
            }
        } else if (prev === 'ready' && curr !== 'ready') {
            sendTelegram(`🟡 <b>DEVICE WA TERPUTUS</b>\n\n📱 Device: ${label}\n⚠️ Status: ${curr}\n💡 Perlu scan ulang QR Code`);
            log(`🟡 WA Device terputus: ${device.name} (${curr})`);
        } else if (prev !== 'ready' && curr === 'ready') {
            sendTelegram(`✅ <b>DEVICE WA TERHUBUNG KEMBALI</b>\n\n📱 Device: ${label}\n✅ Status: Siap digunakan`);
            log(`✅ WA Device kembali: ${device.name}`);
        }

        state.wa_devices[device.id] = curr;
    }

    // --- CEK DEFAULT DEVICE ---
    try {
        const cfgRes = await fetch(config.WA_API.url + '/api/pengaturan', { timeout: 5000 });
        const cfgJson = await cfgRes.json();
        const defaultId = cfgJson.data?.defaultDeviceId || null;
        const prevDefault = state.wa_devices['__default__'];

        if (!defaultId) {
            if (prevDefault !== 'UNSET') {
                sendTelegram(`⚠️ <b>DEFAULT DEVICE WA BELUM DI-SET</b>\n\n📱 Tidak ada device default aktif.\n💡 Set default device agar pesan otomatis bisa terkirim.\n<b>Server:</b> ${config.WA_API.name}`);
                log('⚠️ WA default device belum di-set');
                state.wa_devices['__default__'] = 'UNSET';
            }
        } else {
            const defaultDevice = devices.find(d => d.id === defaultId);
            const defaultName = defaultDevice ? defaultDevice.name : defaultId;
            const defaultStatus = defaultDevice ? defaultDevice.status : 'unknown';

            if (prevDefault && prevDefault !== 'UNSET' && prevDefault !== defaultId) {
                const prevDevice = devices.find(d => d.id === prevDefault);
                const prevName = prevDevice ? prevDevice.name : prevDefault;
                sendTelegram(`🔄 <b>DEFAULT DEVICE WA BERUBAH</b>\n\n📤 Sebelumnya: <b>${prevName}</b>\n📥 Sekarang: <b>${defaultName}</b>\n<b>Server:</b> ${config.WA_API.name}`);
                log(`🔄 WA default device berubah: ${prevName} → ${defaultName}`);
            }

            if (defaultStatus !== 'ready') {
                const alertKey = '__default_down__';
                if (!state.wa_devices[alertKey]) {
                    sendTelegram(`🚨 <b>DEFAULT DEVICE WA TERPUTUS!</b>\n\n📱 Device: <b>${defaultName}</b>\n⚠️ Status: ${defaultStatus}\n💡 Pesan otomatis TIDAK AKAN TERKIRIM sampai device reconnect!\n<b>Server:</b> ${config.WA_API.name}`);
                    log(`🚨 WA default device terputus: ${defaultName}`);
                    state.wa_devices[alertKey] = true;
                }
            } else {
                if (state.wa_devices['__default_down__']) {
                    sendTelegram(`✅ <b>DEFAULT DEVICE WA NORMAL KEMBALI</b>\n\n📱 Device: <b>${defaultName}</b>\n✅ Status: Siap mengirim pesan\n<b>Server:</b> ${config.WA_API.name}`);
                    log(`✅ WA default device kembali: ${defaultName}`);
                    state.wa_devices['__default_down__'] = false;
                }
            }

            state.wa_devices['__default__'] = defaultId;
        }
    } catch(e) {
        log(`⚠️ Gagal cek default device: ${e.message}`);
    }
}

async function checkEndpoints() {
    log("🔍 Checking Endpoints...");
    for (const item of config.ENDPOINTS) {
        let status = 'UP';
        let errorMsg = '';
        let startTime = Date.now();

        try {
            const res = await fetch(item.url, { timeout: 10000 });
            if (!res.ok) {
                status = 'DOWN';
                errorMsg = `HTTP ${res.status}`;
            }
        } catch (e) {
            status = 'DOWN';
            errorMsg = e.message;
        }

        const prevState = state.endpoints[item.url] || 'UP';

        if (status === 'DOWN' && prevState === 'UP') {
            await sendTelegram(`🔴 <b>ENDPOINT MATI</b>\n\n<b>Nama:</b> ${item.name}\n<b>URL:</b> ${item.url}\n<b>Error:</b> ${errorMsg}\n<b>Server:</b> ${config.SERVER_NAME}`);
            log(`🔴 Alert Sent: ${item.name} is DOWN`);
        } else if (status === 'UP' && prevState === 'DOWN') {
            await sendTelegram(`🟢 <b>ENDPOINT NORMAL KEMBALI</b>\n\n<b>Nama:</b> ${item.name}\n<b>URL:</b> ${item.url}\n<b>Status:</b> Kembali Online\n<b>Server:</b> ${config.SERVER_NAME}`);
            log(`🟢 Alert Sent: ${item.name} is UP`);
        }

        state.endpoints[item.url] = status;
    }
}

function checkServices() {
    log("🔍 Checking Services...");
    for (const item of config.SERVICES) {
        let isRunning = false;
        try {
            const output = execSync(`systemctl is-active ${item.service}`).toString().trim();
            isRunning = (output === 'active');
        } catch (e) {
            isRunning = false;
        }

        const prevStatus = state.services[item.service] || 'active';
        const currentStatus = isRunning ? 'active' : 'inactive';

        if (currentStatus === 'inactive' && prevStatus === 'active') {
            sendTelegram(`🚨 <b>SERVICE MATI</b>\n\n<b>Layanan:</b> ${item.name} (${item.service})\n<b>Status:</b> Tidak Aktif!\n<b>Server:</b> ${config.SERVER_NAME}`);
            log(`🚨 Alert Sent: ${item.name} is Inactive`);
        } else if (currentStatus === 'active' && prevStatus === 'inactive') {
            sendTelegram(`✅ <b>SERVICE NORMAL KEMBALI</b>\n\n<b>Layanan:</b> ${item.name}\n<b>Status:</b> Sedang Berjalan\n<b>Server:</b> ${config.SERVER_NAME}`);
            log(`✅ Alert Sent: ${item.name} is Active`);
        }

        state.services[item.service] = currentStatus;
    }
}

// --- HELPER: label proses dengan nama yang lebih informatif ---
function labelProcess(rawCmd) {
    if (rawCmd.includes('containerd-shim') || rawCmd.includes('runc')) return '[Docker] container-runtime';
    if (rawCmd.includes('/usr/bin/dockerd')) return '[Docker] dockerd (engine)';
    if (rawCmd.includes('/usr/bin/containerd')) return '[Docker] containerd';

    const nodeMatch = rawCmd.match(/node\s+([^\s]+)/);
    if (nodeMatch) {
        let script = nodeMatch[1];
        if (script === '-e' || script.startsWith('--')) return `[Node] inline-script (${script})`;
        script = script.split('/').slice(-2).join('/');
        return `[Node] ${script}`;
    }

    if (rawCmd.startsWith('postgres:')) return `[DB] ${rawCmd.substring(0, 45)}`;
    if (rawCmd.includes('supabase')) return `[Supabase] ${rawCmd.split('/').pop().substring(0, 30)}`;
    if (rawCmd.includes('apache2') || rawCmd.includes('httpd')) return '[Web] apache2';
    if (rawCmd.includes('nginx')) return '[Web] nginx';
    if (rawCmd.includes('php')) return '[Web] php-fpm';

    return rawCmd.substring(0, 45).trim();
}

function getTopProcesses(sortField, count = 5) {
    try {
        if (sortField === 'pcpu') {
            const topOutput = execSync(`top -b -n 1 | tail -n +8 | head -n ${count}`).toString().trim().split('\n');
            return topOutput.map(line => {
                const parts = line.trim().split(/\s+/);
                const usage = parts[8];
                const cmd = parts.slice(11).join(' ');
                return `▪ ${labelProcess(cmd)} (${usage}%)`;
            }).join('\n');
        } else {
            const psOutput = execSync(`ps -eo ${sortField},args --sort=-${sortField} | head -n ${count + 1}`)
                .toString().trim().split('\n').slice(1);
            return psOutput.map(line => {
                const parts = line.trim().split(/\s+/);
                const usage = parts[0];
                const rawCmd = parts.slice(1).join(' ');
                return `▪ ${labelProcess(rawCmd)} (${usage}%)`;
            }).join('\n');
        }
    } catch (e) {
        return `⚠️ Gagal mengambil daftar proses: ${e.message}`;
    }
}

function checkResources() {
    log("🔍 Checking Server Resources...");
    const COOLDOWN_MS = 30 * 60 * 1000;
    const DISK_COOLDOWN_MS = 6 * 60 * 60 * 1000;

    // 1. CPU
    try {
        const cpuLoad = parseFloat(execSync("top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\\([0-9.]*\\)%* id.*/\\1/' | awk '{print 100 - $1}'").toString().trim());

        if (cpuLoad > config.THRESHOLDS.CPU) {
            state.resources.cpu.consecutive_high = (state.resources.cpu.consecutive_high || 0) + 1;
            log(`⚠️ CPU High detected (${cpuLoad.toFixed(1)}%). Count: ${state.resources.cpu.consecutive_high}`);

            const now = Date.now();
            const minCount = config.THRESHOLDS.CPU_ALERT_MIN_COUNT || 2;

            if (state.resources.cpu.consecutive_high >= minCount) {
                if (!state.resources.cpu.is_high || now - state.resources.cpu.last_alert > COOLDOWN_MS) {
                    let topProcs = '';
                    try { topProcs = `\n\n<b>🔥 Top 5 Proses Besar:</b>\n${getTopProcesses('pcpu')}`; } catch(e) {}

                    const label = state.resources.cpu.is_high ? '⚠️ CPU MASIH TINGGI' : '⚠️ PENGGUNAAN CPU TINGGI (Stabil)';
                    sendTelegram(`${label}\n\n<b>Penggunaan:</b> ${cpuLoad.toFixed(1)}%\n<b>Batas Maksimal:</b> ${config.THRESHOLDS.CPU}%\n<b>Durasi:</b> >1 Menit\n<b>Server:</b> ${config.SERVER_NAME}${topProcs}`);
                    state.resources.cpu.last_alert = now;
                    state.resources.cpu.is_high = true;
                }
            }
        } else {
            if (state.resources.cpu.is_high) {
                sendTelegram(`🟢 <b>CPU NORMAL KEMBALI</b>\n\n<b>Penggunaan Saat Ini:</b> ${cpuLoad.toFixed(1)}%\n<b>Batas Maksimal:</b> ${config.THRESHOLDS.CPU}%\n<b>Server:</b> ${config.SERVER_NAME}`);
                state.resources.cpu.is_high = false;
            }
            state.resources.cpu.consecutive_high = 0;
        }
    } catch (e) {
        log(`Error checking CPU: ${e.message}`);
    }

    // 2. RAM
    try {
        const ramUsage = parseInt(execSync("free | grep Mem | awk '{print $3/$2 * 100.0}'").toString().trim());
        if (ramUsage > config.THRESHOLDS.RAM) {
            const now = Date.now();
            if (!state.resources.ram.is_high || now - state.resources.ram.last_alert > COOLDOWN_MS) {
                let topProcs = '';
                try { topProcs = `\n\n<b>🧠 Top 5 Penyedot RAM:</b>\n${getTopProcesses('pmem')}`; } catch(e) {}
                const label = state.resources.ram.is_high ? '⚠️ RAM MASIH TINGGI' : '⚠️ PENGGUNAAN RAM TINGGI';
                sendTelegram(`${label}\n\n<b>Penggunaan:</b> ${ramUsage}%\n<b>Batas Maksimal:</b> ${config.THRESHOLDS.RAM}%\n<b>Server:</b> ${config.SERVER_NAME}${topProcs}`);
                state.resources.ram.last_alert = now;
                state.resources.ram.is_high = true;
            }
        } else if (state.resources.ram.is_high) {
            sendTelegram(`🟢 <b>RAM NORMAL KEMBALI</b>\n\n<b>Penggunaan Saat Ini:</b> ${ramUsage}%\n<b>Batas Maksimal:</b> ${config.THRESHOLDS.RAM}%\n<b>Server:</b> ${config.SERVER_NAME}`);
            state.resources.ram.is_high = false;
        }
    } catch (e) {}

    // 3. Disk
    try {
        const diskUsage = parseInt(execSync("df -h / | tail -1 | awk '{print $5}' | sed 's/%//'").toString().trim());
        if (diskUsage > config.THRESHOLDS.DISK) {
            const now = Date.now();
            if (!state.resources.disk.is_high || now - state.resources.disk.last_alert > DISK_COOLDOWN_MS) {
                sendTelegram(`🚨 <b>PENYIMPANAN HAMPIR PENUH</b>\n\n<b>Terpakai:</b> ${diskUsage}%\n<b>Batas Maksimal:</b> ${config.THRESHOLDS.DISK}%\n<b>Server:</b> ${config.SERVER_NAME}`);
                state.resources.disk.last_alert = now;
                state.resources.disk.is_high = true;
            }
        } else if (state.resources.disk.is_high) {
            sendTelegram(`🟢 <b>PENYIMPANAN KEMBALI AMAN</b>\n\n<b>Terpakai:</b> ${diskUsage}%\n<b>Batas Maksimal:</b> ${config.THRESHOLDS.DISK}%\n<b>Server:</b> ${config.SERVER_NAME}`);
            state.resources.disk.is_high = false;
        }
    } catch (e) {}
}

// --- FEATURE 3: SSL Certificate Check ---
async function checkSSLDomains() {
    const SSL_CHECK_INTERVAL_MS = 6 * 60 * 60 * 1000; // cek setiap 6 jam
    const now = Date.now();
    if (state.last_ssl_check && now - state.last_ssl_check < SSL_CHECK_INTERVAL_MS) return;

    log("🔒 Checking SSL Certificates...");
    if (!state.ssl_cache) state.ssl_cache = {};
    if (!state.ssl_alerts) state.ssl_alerts = {};

    for (const domain of (config.SSL_DOMAINS || [])) {
        try {
            const output = execSync(
                `echo | timeout 5 openssl s_client -connect ${domain}:443 -servername ${domain} 2>/dev/null | openssl x509 -noout -enddate`,
                { timeout: 8000 }
            ).toString().trim();
            const match = output.match(/notAfter=(.+)/);
            if (!match) { state.ssl_cache[domain] = null; continue; }
            const daysLeft = Math.floor((new Date(match[1]) - now) / (1000 * 60 * 60 * 24));
            state.ssl_cache[domain] = daysLeft;

            if (daysLeft <= config.THRESHOLDS.SSL_WARN_DAYS) {
                const lastAlert = state.ssl_alerts[domain] || 0;
                if (now - lastAlert > 24 * 60 * 60 * 1000) {
                    const urgency = daysLeft <= 3 ? '🚨' : '⚠️';
                    await sendTelegram(`${urgency} <b>SSL HAMPIR EXPIRED</b>\n\n<b>Domain:</b> ${domain}\n<b>Sisa:</b> ${daysLeft} hari\n<b>Server:</b> ${config.SERVER_NAME}\n\n💡 Perbarui segera sebelum expired!`);
                    log(`⚠️ SSL expiring: ${domain} (${daysLeft} hari)`);
                    state.ssl_alerts[domain] = now;
                }
            }
        } catch (e) {
            state.ssl_cache[domain] = null;
            log(`Error SSL ${domain}: ${e.message}`);
        }
    }
    state.last_ssl_check = now;
}

// --- FEATURE 4: Backup Summary ---
function getBackupSummary() {
    if (!config.BACKUP_DIRS || config.BACKUP_DIRS.length === 0) return null;

    const lines = [];
    for (const backup of config.BACKUP_DIRS) {
        try {
            const latest = execSync(
                `find ${backup.dir} -type f \\( -name "*.sql.gz" -o -name "*.tar.gz" \\) -printf '%T@ %p\\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-`
            ).toString().trim();

            if (!latest) {
                lines.push(`🔴 ${backup.name}: tidak ada file backup`);
                continue;
            }

            const stat = fs.statSync(latest);
            const ageHours = Math.floor((Date.now() - stat.mtimeMs) / (1000 * 60 * 60));
            const sizeMB = (stat.size / 1024 / 1024).toFixed(1);
            const icon = ageHours <= 13 ? '✅' : '⚠️';
            lines.push(`${icon} ${backup.name}: ${sizeMB} MB (${ageHours}j lalu)`);
        } catch (e) {
            lines.push(`⚠️ ${backup.name}: gagal cek`);
        }
    }
    return lines.join('\n');
}

// --- FEATURE 5: PM2 Crash Loop Detection ---
async function checkPM2Crashes() {
    try {
        const output = execSync('pm2 jlist', { timeout: 5000 }).toString();
        const processes = JSON.parse(output);

        if (!state.pm2_restarts) state.pm2_restarts = {};

        for (const proc of processes) {
            const name = proc.name;
            const restarts = proc.pm2_env?.restart_time || 0;
            const status = proc.pm2_env?.status;
            const prevRestarts = state.pm2_restarts[name + '_count'];
            const prevStatus = state.pm2_restarts[name + '_status'];

            // Crash loop: restart naik >= 3 dalam satu interval cek
            if (prevRestarts !== undefined && (restarts - prevRestarts) >= 3) {
                await sendTelegram(`🚨 <b>PM2 CRASH LOOP TERDETEKSI!</b>\n\n<b>Process:</b> ${name}\n<b>Total Restart:</b> ${restarts}x\n<b>Naik:</b> +${restarts - prevRestarts}x dalam 1 menit\n<b>Status:</b> ${status}\n<b>Server:</b> ${config.SERVER_NAME}\n\n💡 Cek log: <code>pm2 logs ${name} --lines 30</code>`);
                log(`🚨 PM2 crash loop: ${name} (+${restarts - prevRestarts} restarts)`);
            }

            // Status berubah jadi errored
            if (status === 'errored' && prevStatus && prevStatus !== 'errored') {
                await sendTelegram(`🔴 <b>PM2 PROCESS ERROR</b>\n\n<b>Process:</b> ${name}\n<b>Status:</b> errored\n<b>Total Restart:</b> ${restarts}x\n<b>Server:</b> ${config.SERVER_NAME}\n\n💡 Cek log: <code>pm2 logs ${name} --lines 30</code>`);
                log(`🔴 PM2 errored: ${name}`);
            }

            state.pm2_restarts[name + '_count'] = restarts;
            state.pm2_restarts[name + '_status'] = status;
        }
    } catch (e) {
        log(`Error checking PM2: ${e.message}`);
    }
}

// --- DAILY REPORT ---
async function sendDailyReport() {
    const today = new Date().toDateString();
    if (state.last_daily_report === today) return;

    log("📬 Generating Daily Report...");

    // Resource stats
    let diskUsage = "Unknown";
    let ramUsage = "Unknown";
    try {
        diskUsage = execSync("df -h / | tail -1 | awk '{print $3 \" / \" $2 \" (\" $5 \")\"}'").toString().trim();
        ramUsage = execSync("free -h | grep Mem | awk '{print $3 \" / \" $2}'").toString().trim();
    } catch (e) {}

    // Endpoint & service status
    const endpointStatus = Object.entries(state.endpoints)
        .map(([url, status]) => `${status === 'UP' ? '✅' : '🔴'} ${url.replace('https://', '')}`)
        .join('\n') || '—';
    const serviceStatus = Object.entries(state.services)
        .map(([name, status]) => `${status === 'active' ? '✅' : '🚨'} ${name}`)
        .join('\n') || '—';

    // SSL expiry dari cache
    let sslSection = '';
    const sslEntries = Object.entries(state.ssl_cache || {});
    if (sslEntries.length > 0) {
        const sslLines = sslEntries.map(([domain, days]) => {
            if (days === null) return `❓ ${domain}: tidak bisa dicek`;
            const icon = days <= 7 ? '🚨' : days <= 14 ? '⚠️' : '✅';
            return `${icon} ${domain}: ${days} hari`;
        }).join('\n');
        sslSection = `\n\n<b>🔒 SSL Sertifikat:</b>\n${sslLines}`;
    }

    // Backup summary
    let backupSection = '';
    const backupSummary = getBackupSummary();
    if (backupSummary) {
        backupSection = `\n\n<b>💾 Backup Terakhir:</b>\n${backupSummary}`;
    }

    // PM2 process summary
    let pm2Section = '';
    try {
        const pm2Output = execSync('pm2 jlist', { timeout: 5000 }).toString();
        const pm2Procs = JSON.parse(pm2Output);
        const pm2Lines = pm2Procs.map(p => {
            const status = p.pm2_env?.status;
            const restarts = p.pm2_env?.restart_time || 0;
            const icon = status === 'online' ? '✅' : status === 'stopped' ? '⏹' : '🔴';
            return `${icon} ${p.name} (restart: ${restarts}x)`;
        }).join('\n');
        pm2Section = `\n\n<b>⚙️ PM2 Processes:</b>\n${pm2Lines}`;
    } catch (e) {}

    const report = `📊 <b>LAPORAN SERVER HARIAN</b>\n\n<b>Server:</b> ${config.SERVER_NAME}\n<b>Tanggal:</b> ${today}\n\n<b>Kapasitas:</b>\n💾 Disk: ${diskUsage}\n🧠 RAM: ${ramUsage}\n\n<b>Status Layanan:</b>\n${serviceStatus}\n\n<b>Pantauan Endpoint:</b>\n${endpointStatus}${sslSection}${backupSection}${pm2Section}`;

    await sendTelegram(report);
    state.last_daily_report = today;
}

// --- MAIN LOOP ---
async function runMonitor() {
    try {
        await checkEndpoints();
        checkServices();
        checkResources();
        await checkWhatsApp();
        await checkPM2Crashes();
        await checkSSLDomains();

        const hour = new Date().getHours();
        if (hour === 8) {
            await sendDailyReport();
        }

        saveState();
    } catch (e) {
        log(`CRITICAL ERROR in monitor loop: ${e.message}`);
    }
}

log(`🚀 FEZORA MONITOR V2 STARTED (Frequency: ${config.CHECK_INTERVAL_MS / 1000}s)`);
setInterval(runMonitor, config.CHECK_INTERVAL_MS);
runMonitor(); // Run once at start
