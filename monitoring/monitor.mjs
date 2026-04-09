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
    resources: {
        cpu: { last_alert: 0 },
        ram: { last_alert: 0 },
        disk: { last_alert: 0 }
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

function checkResources() {
    log("🔍 Checking Server Resources...");
    
    // 1. CPU
    try {
        const cpuLoad = parseFloat(execSync("top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\\([0-9.]*\\)%* id.*/\\1/' | awk '{print 100 - $1}'").toString().trim());
        if (cpuLoad > config.THRESHOLDS.CPU) {
            const now = Date.now();
            if (now - state.resources.cpu.last_alert > 3600000) { // Limit alert to once per hour
                let topProcs = "";
                try {
                    topProcs = "\n\n<b>🔥 Top 5 Proses Besar:</b>\n" + execSync("ps -eo %cpu,comm --sort=-%cpu | head -n 6 | awk 'NR>1 {print \"▪ \" $2 \" (\" $1 \"%)\"}'").toString().trim();
                } catch(e) {}
                sendTelegram(`⚠️ <b>PENGGUNAAN CPU TINGGI</b>\n\n<b>Penggunaan:</b> ${cpuLoad.toFixed(1)}%\n<b>Batas Maksimal:</b> ${config.THRESHOLDS.CPU}%\n<b>Server:</b> ${config.SERVER_NAME}${topProcs}`);
                state.resources.cpu.last_alert = now;
            }
        }
    } catch (e) {}

    // 2. RAM
    try {
        const ramUsage = parseInt(execSync("free | grep Mem | awk '{print $3/$2 * 100.0}'").toString().trim());
        if (ramUsage > config.THRESHOLDS.RAM) {
            const now = Date.now();
            if (now - state.resources.ram.last_alert > 3600000) {
                let topProcs = "";
                try {
                    topProcs = "\n\n<b>🧠 Top 5 Penyedot RAM:</b>\n" + execSync("ps -eo %mem,comm --sort=-%mem | head -n 6 | awk 'NR>1 {print \"▪ \" $2 \" (\" $1 \"%)\"}'").toString().trim();
                } catch(e) {}
                sendTelegram(`⚠️ <b>PENGGUNAAN RAM TINGGI</b>\n\n<b>Penggunaan:</b> ${ramUsage}%\n<b>Batas Maksimal:</b> ${config.THRESHOLDS.RAM}%\n<b>Server:</b> ${config.SERVER_NAME}${topProcs}`);
                state.resources.ram.last_alert = now;
            }
        }
    } catch (e) {}

    // 3. Disk
    try {
        const diskUsage = parseInt(execSync("df -h / | tail -1 | awk '{print $5}' | sed 's/%//'").toString().trim());
        if (diskUsage > config.THRESHOLDS.DISK) {
            const now = Date.now();
            if (now - state.resources.disk.last_alert > 86400000) { // Limit alert to once per day for disk
                sendTelegram(`🚨 <b>PENYIMPANAN HAMPIR PENUH</b>\n\n<b>Terpakai:</b> ${diskUsage}%\n<b>Batas Maksimal:</b> ${config.THRESHOLDS.DISK}%\n<b>Server:</b> ${config.SERVER_NAME}`);
                state.resources.disk.last_alert = now;
            }
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
