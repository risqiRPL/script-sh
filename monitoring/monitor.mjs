import fs from 'fs';
import { execSync } from 'child_process';
import fetch from 'node-fetch';
import path from 'path';

// --- INITIAL CONFIG ---
const CONFIG_PATH = './config.json';
const STATE_PATH = './state.json';
let config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf-8'));

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
    try { fs.appendFileSync(config.LOG_FILE, line + '\n'); } catch (e) {}
}

function ts() {
    return new Date().toLocaleString('id-ID', {
        day: '2-digit', month: 'short', year: 'numeric',
        hour: '2-digit', minute: '2-digit', hour12: false
    }).replace(',', ' ·');
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
            sendTelegram(`✅ <b>WA BOT ONLINE</b> · ${config.WA_API.name}`);
            state.wa_server_up = true;
        }
    } catch (e) {
        if (state.wa_server_up !== false) {
            sendTelegram(`🔴 <b>WA BOT DOWN</b> · ${config.WA_API.name}\n↳ ${e.message}\n💡 <code>pm2 restart robot-wa</code>`);
            log(`🔴 WA Server down: ${e.message}`);
            state.wa_server_up = false;
        }
        return;
    }

    for (const device of devices) {
        if (config.WA_API.ignore_devices && config.WA_API.ignore_devices.includes(device.id)) continue;

        const prev = state.wa_devices[device.id];
        const curr = device.status;
        const label = `${device.name} (${device.number || device.id})`;

        if (!prev) {
            if (curr === 'ready') {
                sendTelegram(`🟢 <b>WA DEVICE TERHUBUNG</b>\n<code>${label}</code>`);
                log(`🟢 WA Device baru: ${device.name}`);
            }
        } else if (prev === 'ready' && curr !== 'ready') {
            sendTelegram(`🟡 <b>WA DEVICE TERPUTUS</b>\n<code>${label}</code> · status: ${curr}\nScan ulang QR Code diperlukan`);
            log(`🟡 WA Device terputus: ${device.name} (${curr})`);
        } else if (prev !== 'ready' && curr === 'ready') {
            sendTelegram(`✅ <b>WA DEVICE PULIH</b> · <code>${label}</code>`);
            log(`✅ WA Device kembali: ${device.name}`);
        }

        state.wa_devices[device.id] = curr;
    }

    // --- DEFAULT DEVICE ---
    try {
        const cfgRes = await fetch(config.WA_API.url + '/api/pengaturan', { timeout: 5000 });
        const cfgJson = await cfgRes.json();
        const defaultId = cfgJson.data?.defaultDeviceId || null;
        const prevDefault = state.wa_devices['__default__'];

        if (!defaultId) {
            if (prevDefault !== 'UNSET') {
                sendTelegram(`⚠️ <b>DEFAULT DEVICE WA KOSONG</b>\nPesan otomatis tidak akan terkirim\nSet device default di pengaturan`);
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
                sendTelegram(`🔄 <b>DEFAULT DEVICE WA BERUBAH</b>\n${prevName} → <b>${defaultName}</b>`);
                log(`🔄 WA default device berubah: ${prevName} → ${defaultName}`);
            }

            if (defaultStatus !== 'ready') {
                const alertKey = '__default_down__';
                if (!state.wa_devices[alertKey]) {
                    sendTelegram(`🚨 <b>DEFAULT DEVICE WA TERPUTUS!</b>\n<b>${defaultName}</b> · status: ${defaultStatus}\n⛔ Pesan otomatis berhenti sampai device reconnect`);
                    log(`🚨 WA default device terputus: ${defaultName}`);
                    state.wa_devices[alertKey] = true;
                }
            } else {
                if (state.wa_devices['__default_down__']) {
                    sendTelegram(`✅ <b>DEFAULT DEVICE PULIH</b> · ${defaultName}\nPesan otomatis kembali aktif`);
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

        try {
            const res = await fetch(item.url, { timeout: 10000 });
            if (!res.ok) { status = 'DOWN'; errorMsg = `HTTP ${res.status}`; }
        } catch (e) {
            status = 'DOWN';
            errorMsg = e.message;
        }

        const prevState = state.endpoints[item.url] || 'UP';

        if (status === 'DOWN' && prevState === 'UP') {
            await sendTelegram(`🔴 <b>ENDPOINT DOWN</b>\n<b>${item.name}</b> · <code>${item.url.replace('https://', '')}</code>\n↳ ${errorMsg}`);
            log(`🔴 DOWN: ${item.name}`);
        } else if (status === 'UP' && prevState === 'DOWN') {
            await sendTelegram(`🟢 <b>ENDPOINT PULIH</b> · ${item.name}`);
            log(`🟢 UP: ${item.name}`);
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
        } catch (e) { isRunning = false; }

        const prevStatus = state.services[item.service] || 'active';
        const currentStatus = isRunning ? 'active' : 'inactive';

        if (currentStatus === 'inactive' && prevStatus === 'active') {
            sendTelegram(`🚨 <b>SERVICE MATI</b>\n${item.name} · <code>${item.service}</code>\n💡 <code>systemctl restart ${item.service}</code>`);
            log(`🚨 Service mati: ${item.name}`);
        } else if (currentStatus === 'active' && prevStatus === 'inactive') {
            sendTelegram(`✅ <b>SERVICE PULIH</b> · ${item.name}`);
            log(`✅ Service pulih: ${item.name}`);
        }

        state.services[item.service] = currentStatus;
    }
}

function labelProcess(rawCmd) {
    if (rawCmd.includes('containerd-shim') || rawCmd.includes('runc')) return '[Docker] container-runtime';
    if (rawCmd.includes('/usr/bin/dockerd')) return '[Docker] dockerd';
    if (rawCmd.includes('/usr/bin/containerd')) return '[Docker] containerd';
    const nodeMatch = rawCmd.match(/node\s+([^\s]+)/);
    if (nodeMatch) {
        let script = nodeMatch[1];
        if (script === '-e' || script.startsWith('--')) return `[Node] inline`;
        return `[Node] ${script.split('/').slice(-2).join('/')}`;
    }
    if (rawCmd.startsWith('postgres:')) return `[DB] ${rawCmd.substring(0, 40)}`;
    if (rawCmd.includes('supabase')) return `[Supabase] ${rawCmd.split('/').pop().substring(0, 25)}`;
    if (rawCmd.includes('apache2') || rawCmd.includes('httpd')) return '[Web] apache2';
    if (rawCmd.includes('nginx')) return '[Web] nginx';
    if (rawCmd.includes('php')) return '[Web] php-fpm';
    return rawCmd.substring(0, 40).trim();
}

function getTopProcesses(sortField, count = 5) {
    try {
        if (sortField === 'pcpu') {
            const topOutput = execSync(`top -b -n 1 | tail -n +8 | head -n ${count}`).toString().trim().split('\n');
            return topOutput.map(line => {
                const parts = line.trim().split(/\s+/);
                return `  ▪ ${labelProcess(parts.slice(11).join(' '))} (${parts[8]}%)`;
            }).join('\n');
        } else {
            const psOutput = execSync(`ps -eo ${sortField},args --sort=-${sortField} | head -n ${count + 1}`)
                .toString().trim().split('\n').slice(1);
            return psOutput.map(line => {
                const parts = line.trim().split(/\s+/);
                return `  ▪ ${labelProcess(parts.slice(1).join(' '))} (${parts[0]}%)`;
            }).join('\n');
        }
    } catch (e) {
        return `  ⚠️ Gagal ambil proses: ${e.message}`;
    }
}

function checkResources() {
    log("🔍 Checking Server Resources...");
    const COOLDOWN_MS = 30 * 60 * 1000;
    const DISK_COOLDOWN_MS = 6 * 60 * 60 * 1000;

    // CPU
    try {
        const cpuLoad = parseFloat(execSync("top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\\([0-9.]*\\)%* id.*/\\1/' | awk '{print 100 - $1}'").toString().trim());

        if (cpuLoad > config.THRESHOLDS.CPU) {
            state.resources.cpu.consecutive_high = (state.resources.cpu.consecutive_high || 0) + 1;
            const now = Date.now();
            const minCount = config.THRESHOLDS.CPU_ALERT_MIN_COUNT || 2;

            if (state.resources.cpu.consecutive_high >= minCount) {
                if (!state.resources.cpu.is_high || now - state.resources.cpu.last_alert > COOLDOWN_MS) {
                    let topProcs = '';
                    try { topProcs = `\n<b>Top Proses:</b>\n${getTopProcesses('pcpu')}`; } catch(e) {}
                    const tag = state.resources.cpu.is_high ? '⚠️ CPU MASIH TINGGI' : '⚠️ CPU TINGGI';
                    sendTelegram(`${tag} · <code>${cpuLoad.toFixed(1)}%</code> (batas ${config.THRESHOLDS.CPU}%)${topProcs}`);
                    state.resources.cpu.last_alert = now;
                    state.resources.cpu.is_high = true;
                }
            }
        } else {
            if (state.resources.cpu.is_high) {
                sendTelegram(`🟢 <b>CPU NORMAL</b> · <code>${cpuLoad.toFixed(1)}%</code>`);
                state.resources.cpu.is_high = false;
            }
            state.resources.cpu.consecutive_high = 0;
        }
    } catch (e) { log(`Error CPU: ${e.message}`); }

    // RAM
    try {
        const ramUsage = parseInt(execSync("free | grep Mem | awk '{print $3/$2 * 100.0}'").toString().trim());
        if (ramUsage > config.THRESHOLDS.RAM) {
            const now = Date.now();
            if (!state.resources.ram.is_high || now - state.resources.ram.last_alert > COOLDOWN_MS) {
                let topProcs = '';
                try { topProcs = `\n<b>Top Proses:</b>\n${getTopProcesses('pmem')}`; } catch(e) {}
                const tag = state.resources.ram.is_high ? '⚠️ RAM MASIH TINGGI' : '⚠️ RAM TINGGI';
                sendTelegram(`${tag} · <code>${ramUsage}%</code> (batas ${config.THRESHOLDS.RAM}%)${topProcs}`);
                state.resources.ram.last_alert = now;
                state.resources.ram.is_high = true;
            }
        } else if (state.resources.ram.is_high) {
            sendTelegram(`🟢 <b>RAM NORMAL</b> · <code>${ramUsage}%</code>`);
            state.resources.ram.is_high = false;
        }
    } catch (e) {}

    // Disk
    try {
        const diskUsage = parseInt(execSync("df -h / | tail -1 | awk '{print $5}' | sed 's/%//'").toString().trim());
        if (diskUsage > config.THRESHOLDS.DISK) {
            const now = Date.now();
            if (!state.resources.disk.is_high || now - state.resources.disk.last_alert > DISK_COOLDOWN_MS) {
                sendTelegram(`🚨 <b>DISK HAMPIR PENUH</b> · <code>${diskUsage}%</code> (batas ${config.THRESHOLDS.DISK}%)\nHapus file lama atau perluas kapasitas`);
                state.resources.disk.last_alert = now;
                state.resources.disk.is_high = true;
            }
        } else if (state.resources.disk.is_high) {
            sendTelegram(`🟢 <b>DISK AMAN</b> · <code>${diskUsage}%</code>`);
            state.resources.disk.is_high = false;
        }
    } catch (e) {}
}

// --- SSL Check (setiap 6 jam) ---
async function checkSSLDomains() {
    const SSL_CHECK_INTERVAL_MS = 6 * 60 * 60 * 1000;
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
                    await sendTelegram(`${urgency} <b>SSL HAMPIR EXPIRED</b>\n<code>${domain}</code> · sisa ${daysLeft} hari\n💡 <code>certbot renew --cert-name ${domain}</code>`);
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

// --- Backup Summary ---
function getBackupSummary() {
    if (!config.BACKUP_DIRS || config.BACKUP_DIRS.length === 0) return null;

    const lines = [];
    for (const backup of config.BACKUP_DIRS) {
        try {
            const latest = execSync(
                `find ${backup.dir} -type f \\( -name "*.sql.gz" -o -name "*.tar.gz" \\) -printf '%T@ %p\\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-`
            ).toString().trim();
            if (!latest) { lines.push(`🔴 ${backup.name}: tidak ada backup`); continue; }
            const stat = fs.statSync(latest);
            const ageHours = Math.floor((Date.now() - stat.mtimeMs) / (1000 * 60 * 60));
            const sizeMB = (stat.size / 1024 / 1024).toFixed(1);
            const icon = ageHours <= 13 ? '✅' : '⚠️';
            lines.push(`${icon} ${backup.name}  ${sizeMB} MB · ${ageHours}j lalu`);
        } catch (e) {
            lines.push(`⚠️ ${backup.name}: gagal cek`);
        }
    }
    return lines.join('\n');
}

// --- PM2 Crash Detection ---
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

            if (prevRestarts !== undefined && (restarts - prevRestarts) >= 3) {
                await sendTelegram(`🚨 <b>PM2 CRASH LOOP</b>\n<code>${name}</code> · +${restarts - prevRestarts} restart (total: ${restarts}x)\n💡 <code>pm2 logs ${name} --lines 30</code>`);
                log(`🚨 PM2 crash loop: ${name} (+${restarts - prevRestarts})`);
            }

            if (status === 'errored' && prevStatus && prevStatus !== 'errored') {
                await sendTelegram(`🔴 <b>PM2 PROCESS ERROR</b>\n<code>${name}</code> · status: errored · total: ${restarts}x restart\n💡 <code>pm2 logs ${name} --lines 30</code>`);
                log(`🔴 PM2 errored: ${name}`);
            }

            state.pm2_restarts[name + '_count'] = restarts;
            state.pm2_restarts[name + '_status'] = status;
        }
    } catch (e) {
        log(`Error PM2: ${e.message}`);
    }
}

// --- DAILY REPORT ---
async function sendDailyReport() {
    const today = new Date().toDateString();
    if (state.last_daily_report === today) return;

    log("📬 Generating Daily Report...");

    // Resource
    let diskLine = '—', ramLine = '—';
    try {
        diskLine = execSync("df -h / | tail -1 | awk '{print $3\"/\"$2\" (\"$5\")\"}' ").toString().trim();
        ramLine  = execSync("free -h | grep Mem | awk '{print $3\"/\"$2}'").toString().trim();
    } catch (e) {}

    // Layanan & Endpoint summary
    const totalServices  = Object.keys(state.services).length;
    const activeServices = Object.values(state.services).filter(s => s === 'active').length;
    const totalEndpoints = Object.keys(state.endpoints).length;
    const upEndpoints    = Object.values(state.endpoints).filter(s => s === 'UP').length;
    const svcIcon  = activeServices === totalServices  ? '🟢' : '🔴';
    const epIcon   = upEndpoints    === totalEndpoints ? '🟢' : '🔴';

    // SSL — hanya tampilkan yang bermasalah, sisanya ringkas
    let sslSection = '';
    const sslEntries = Object.entries(state.ssl_cache || {});
    if (sslEntries.length > 0) {
        const warn = sslEntries.filter(([, d]) => d !== null && d <= 30).sort((a, b) => a[1] - b[1]);
        if (warn.length === 0) {
            sslSection = `\n🔒 <b>SSL</b>  ${sslEntries.length} domain · semua aman`;
        } else {
            const warnLines = warn.map(([domain, days]) => {
                const icon = days <= 3 ? '🚨' : days <= 7 ? '🔴' : '⚠️';
                return `  ${icon} ${domain} — ${days} hari`;
            }).join('\n');
            const safeCount = sslEntries.length - warn.length;
            sslSection = `\n🔒 <b>SSL</b>  ${warn.length} perlu perhatian\n${warnLines}` +
                (safeCount > 0 ? `\n  ✅ ${safeCount} domain lainnya aman` : '');
        }
    }

    // Backup
    let backupSection = '';
    const backupSummary = getBackupSummary();
    if (backupSummary) {
        backupSection = `\n\n💾 <b>Backup</b>\n${backupSummary}`;
    }

    // PM2
    let pm2Section = '';
    try {
        const pm2Procs = JSON.parse(execSync('pm2 jlist', { timeout: 5000 }).toString());
        const online  = pm2Procs.filter(p => p.pm2_env?.status === 'online');
        const stopped = pm2Procs.filter(p => p.pm2_env?.status === 'stopped');
        const errored = pm2Procs.filter(p => p.pm2_env?.status === 'errored');
        const pm2Icon = errored.length > 0 ? '🔴' : '🟢';

        const onlineLines = online.map(p => `${p.name}(${p.pm2_env?.restart_time || 0}↺)`).join(' · ');
        const stoppedLine = stopped.length > 0 ? `\n  ⏹ stopped: ${stopped.map(p => p.name).join(', ')}` : '';
        const erroredLine = errored.length > 0 ? `\n  🔴 errored: ${errored.map(p => p.name).join(', ')}` : '';

        pm2Section = `\n\n⚙️ <b>PM2</b>  ${pm2Icon} ${online.length} online · ${stopped.length} stopped` +
            (errored.length > 0 ? ` · ${errored.length} error` : '') +
            `\n${onlineLines}${stoppedLine}${erroredLine}`;
    } catch (e) {}

    const dateStr = new Date().toLocaleDateString('id-ID', {
        weekday: 'short', day: '2-digit', month: 'short', year: 'numeric'
    });

    const report =
        `📊 <b>LAPORAN HARIAN</b> · ${config.SERVER_NAME}\n` +
        `${dateStr}\n` +
        `\n` +
        `💾 Disk  <code>${diskLine}</code>\n` +
        `🧠 RAM   <code>${ramLine}</code>\n` +
        `\n` +
        `${svcIcon} <b>Layanan</b>   <code>${activeServices}/${totalServices} aktif</code>\n` +
        `${epIcon} <b>Endpoint</b>  <code>${upEndpoints}/${totalEndpoints} UP</code>` +
        sslSection +
        backupSection +
        pm2Section;

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
        if (hour === 8) await sendDailyReport();

        saveState();
    } catch (e) {
        log(`CRITICAL ERROR: ${e.message}`);
    }
}

log(`🚀 FEZORA MONITOR V2 STARTED (Frequency: ${config.CHECK_INTERVAL_MS / 1000}s)`);
setInterval(runMonitor, config.CHECK_INTERVAL_MS);
runMonitor();
