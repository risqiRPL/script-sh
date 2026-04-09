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
    wa_devices: {},         // track WA device states
    wa_server_up: true,     // track WA server status
    resources: {
        cpu:  { last_alert: 0, is_high: false, consecutive_high: 0 },
        ram:  { last_alert: 0, is_high: false },
        disk: { last_alert: 0, is_high: false }
    },
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
    } catch (e) {
        // Fallback if log file not writable
    }
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

        // Server baru nyala kembali setelah mati
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
        // Lewati device yang memang sengaja di-ignore
        if (config.WA_API.ignore_devices && config.WA_API.ignore_devices.includes(device.id)) continue;

        const prev = state.wa_devices[device.id];
        const curr = device.status;
        const label = `<b>${device.name}</b> (${device.number || device.id})`;

        if (!prev) {
            // Device baru pertama kali terdeteksi
            if (curr === 'ready') {
                sendTelegram(`🟢 <b>DEVICE WA BARU TERHUBUNG</b>\n\n📱 Device: ${label}\n✅ Status: Siap digunakan`);
                log(`🟢 WA Device baru: ${device.name}`);
            }
        } else if (prev === 'ready' && curr !== 'ready') {
            // Device yang tadinya ready, sekarang mati/disconnect
            sendTelegram(`🟡 <b>DEVICE WA TERPUTUS</b>\n\n📱 Device: ${label}\n⚠️ Status: ${curr}\n💡 Perlu scan ulang QR Code`);
            log(`🟡 WA Device terputus: ${device.name} (${curr})`);
        } else if (prev !== 'ready' && curr === 'ready') {
            // Device yang tadinya disconnect, kini ready kembali
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
            // Default belum di-set sama sekali
            if (prevDefault !== 'UNSET') {
                sendTelegram(`⚠️ <b>DEFAULT DEVICE WA BELUM DI-SET</b>\n\n📱 Tidak ada device default aktif.\n💡 Set default device agar pesan otomatis bisa terkirim.\n<b>Server:</b> ${config.WA_API.name}`);
                log('⚠️ WA default device belum di-set');
                state.wa_devices['__default__'] = 'UNSET';
            }
        } else {
            // Cari nama device berdasarkan ID
            const defaultDevice = devices.find(d => d.id === defaultId);
            const defaultName = defaultDevice ? defaultDevice.name : defaultId;
            const defaultStatus = defaultDevice ? defaultDevice.status : 'unknown';

            // Default device berubah
            if (prevDefault && prevDefault !== 'UNSET' && prevDefault !== defaultId) {
                const prevDevice = devices.find(d => d.id === prevDefault);
                const prevName = prevDevice ? prevDevice.name : prevDefault;
                sendTelegram(`🔄 <b>DEFAULT DEVICE WA BERUBAH</b>\n\n📤 Sebelumnya: <b>${prevName}</b>\n📥 Sekarang: <b>${defaultName}</b>\n<b>Server:</b> ${config.WA_API.name}`);
                log(`🔄 WA default device berubah: ${prevName} → ${defaultName}`);
            }

            // Default device terputus — ini kritis!
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
        let responseTime = 0;

        try {
            const res = await fetch(item.url, { timeout: 10000 });
            responseTime = Date.now() - startTime;
            if (!res.ok) {
                status = 'DOWN';
                errorMsg = `HTTP ${res.status}`;
            }
        } catch (e) {
            status = 'DOWN';
            errorMsg = e.message;
        }

        const prevState = state.endpoints[item.url] || 'UP';

        // State Change Logic
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
    // Tandai proses Docker container
    if (rawCmd.includes('containerd-shim') || rawCmd.includes('runc')) return '[Docker] container-runtime';
    if (rawCmd.includes('/usr/bin/dockerd')) return '[Docker] dockerd (engine)';
    if (rawCmd.includes('/usr/bin/containerd')) return '[Docker] containerd';

    // Node.js — tampilkan nama script/folder
    const nodeMatch = rawCmd.match(/node\s+([^\s]+)/);
    if (nodeMatch) {
        let script = nodeMatch[1];
        if (script === '-e' || script.startsWith('--')) {
            // Jika node -e, coba ambil cuplikan scriptnya jika ada
            return `[Node] inline-script (${script})`;
        }
        script = script.split('/').slice(-2).join('/');
        return `[Node] ${script}`;
    }

    // PostgreSQL / Supabase
    if (rawCmd.startsWith('postgres:')) return `[DB] ${rawCmd.substring(0, 45)}`;
    if (rawCmd.includes('supabase')) return `[Supabase] ${rawCmd.split('/').pop().substring(0, 30)}`;

    // Apache/PHP/Nginx
    if (rawCmd.includes('apache2') || rawCmd.includes('httpd')) return '[Web] apache2';
    if (rawCmd.includes('nginx')) return '[Web] nginx';
    if (rawCmd.includes('php')) return '[Web] php-fpm';

    // Fallback - potong 40 karakter
    return rawCmd.substring(0, 45).trim();
}

function getTopProcesses(sortField, count = 5) {
    try {
        if (sortField === 'pcpu') {
            // Gunakan top -b (batch mode) untuk mendapatkan data real-time yang akurat di Linux
            // Skip 7 baris header, ambil 5 baris pertama
            // Output top: PID USER PR NI VIRT RES SHR S %CPU %MEM TIME+ COMMAND
            const topOutput = execSync(`top -b -n 1 | tail -n +8 | head -n ${count}`).toString().trim().split('\n');
            return topOutput.map(line => {
                const parts = line.trim().split(/\s+/);
                const usage = parts[8]; // Kolom %CPU biasanya ke-9 (index 8)
                const cmd = parts.slice(11).join(' '); // Kolom COMMAND biasanya ke-12 (index 11)
                return `▪ ${labelProcess(cmd)} (${usage}%)`;
            }).join('\n');
        } else {
            // Untuk RAM (pmem) tetap pakai ps karena lebih stabil pengukurannya
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
    const COOLDOWN_MS = 30 * 60 * 1000; // 30 menit
    const DISK_COOLDOWN_MS = 6 * 60 * 60 * 1000; // 6 jam untuk disk

    // 1. CPU
    try {
        const cpuLoad = parseFloat(execSync("top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\\([0-9.]*\\)%* id.*/\\1/' | awk '{print 100 - $1}'").toString().trim());
        
        if (cpuLoad > config.THRESHOLDS.CPU) {
            state.resources.cpu.consecutive_high = (state.resources.cpu.consecutive_high || 0) + 1;
            log(`⚠️ CPU High detected (${cpuLoad.toFixed(1)}%). Count: ${state.resources.cpu.consecutive_high}`);

            const now = Date.now();
            // Kirim notif hanya jika sudah 2x berturut-turut (sekitar 2 menit)
            if (state.resources.cpu.consecutive_high >= 2) {
                if (!state.resources.cpu.is_high || now - state.resources.cpu.last_alert > COOLDOWN_MS) {
                    let topProcs = '';
                    try {
                        topProcs = `\n\n<b>🔥 Top 5 Proses Besar:</b>\n${getTopProcesses('pcpu')}`;
                    } catch(e) {}
                    
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
                try {
                    topProcs = `\n\n<b>🧠 Top 5 Penyedot RAM:</b>\n${getTopProcesses('pmem')}`;
                } catch(e) {}
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

async function sendDailyReport() {
    const today = new Date().toDateString();
    if (state.last_daily_report === today) return;

    log("📬 Generating Daily Report...");
    
    // Get Disk & RAM Stats
    let diskUsage = "Unknown";
    let ramUsage = "Unknown";
    try {
        diskUsage = execSync("df -h / | tail -1 | awk '{print $3 \" / \" $2 \" (\" $5 \")\"}'").toString().trim();
        ramUsage = execSync("free -h | grep Mem | awk '{print $3 \" / \" $2}'").toString().trim();
    } catch (e) {}

    // Simple Report Stats
    let endpointStatus = Object.entries(state.endpoints).map(([url, status]) => `${status === 'UP' ? '✅' : '🔴'} ${url.replace('https://', '')}`).join('\n');
    let serviceStatus = Object.entries(state.services).map(([name, status]) => `${status === 'active' ? '✅' : '🚨'} ${name}`).join('\n');

    const report = `📊 <b>LAPORAN SERVER HARIAN</b>\n\n<b>Server:</b> ${config.SERVER_NAME}\n<b>Tanggal:</b> ${today}\n\n<b>Kapasitas Tersisa:</b>\n💾 Disk: ${diskUsage}\n🧠 RAM: ${ramUsage}\n\n<b>Status Layanan:</b>\n${serviceStatus}\n\n<b>Pantauan Endpoint:</b>\n${endpointStatus}\n\n<i>✓ Semua sistem berjalan normal.</i>`;
    
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

        // Report Logic (Check once an hour if it's report time)
        const hour = new Date().getHours();
        if (hour === 8) { // Send at 8 AM
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
