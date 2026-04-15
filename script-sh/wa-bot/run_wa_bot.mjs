import { createClient } from '@supabase/supabase-js';

const supabaseUrl = 'https://njnbfugdpwuskfvzolbs.supabase.co';
const supabaseKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5qbmJmdWdkcHd1c2tmdnpvbGJzIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3MzA3NjgxMiwiZXhwIjoyMDg4NjUyODEyfQ.ovwzUHan0lprhvcRt4pr2Tw5_byKaVPxqVFkE2CA5yE';
const supabase = createClient(supabaseUrl, supabaseKey);

console.log('🤖 FEZORA WA-BOT DAEMON STARTED...');
console.log('Menunggu pesan masuk ke antrean Supabase...\n\n');

async function processQueue() {
    try {
        // Ambil pesan pending, urutkan dari prioritas tetinggi (1) hingga terendah (10)
        const { data: queue, error: qErr } = await supabase
            .from('whatsapp_queue')
            .select('*')
            .eq('status', 'pending')
            .order('priority', { ascending: true })
            .order('created_at', { ascending: true })
            .limit(5);

        if (qErr) throw qErr;
        if (!queue || queue.length === 0) return; // Tidak ada pesan antre

        // Ambil konfigurasi API URL dan Device ID dari frontend
        const { data: configData, error: cErr } = await supabase.from('system_settings').select('value').eq('key', 'whatsapp_config').maybeSingle();
        if (cErr) throw cErr;

        const waApiUrl = configData?.value?.api_url;
        const waDeviceId = configData?.value?.device_id;

        if (!waApiUrl) {
            console.log('⚠️ API URL belum dikonfigurasi di pengaturan frontend.');
            return;
        }

        const fullWaUrl = waApiUrl.endsWith('/send-message') ? waApiUrl : `${waApiUrl.replace(/\/$/, '')}/send-message`;

        for (const item of queue) {
            console.log(`[▶ PROSES] Mengirim pesan ke: ${item.target_number}`);

            // Buat Anti-bot format
            const now = new Date();
            const timeString = now.toLocaleTimeString('id-ID', { hour: '2-digit', minute: '2-digit' });
            const footers = [
               "Tetap semangat! 💪", "Jangan lupa buka aplikasinya! 📱", 
               "Semoga lancar terus! ✨", "Cek detail di aplikasi ya! ✅", 
               "Safety first! 👷‍♂️", "Semangat kerjanya kak! 🚀"
            ];
            const randomFooter = footers[Math.floor(Math.random() * footers.length)];
            let originalMessage = item.message_payload?.message || '';

            // Hindari mengganda tag footer jika sudah ada
            if (!originalMessage.includes('WIB_ •')) {
               originalMessage += `\n\n_${timeString} WIB_ • ${randomFooter}`;
            }

            const formData = new URLSearchParams();
            if (waDeviceId) {
                formData.append('deviceId', waDeviceId);
            }
            formData.append('number', item.target_number);
            formData.append('message', originalMessage);

            try {
                const response = await fetch(fullWaUrl, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                    body: formData.toString()
                });

                if (response.ok) {
                    const { error: updateErr } = await supabase
                        .from('whatsapp_queue')
                        .update({ status: 'sent', updated_at: new Date().toISOString() })
                        .eq('id', item.id);
                    if (updateErr) {
                        console.error(`[✖ UPDATE GAGAL] Tidak bisa set status=sent untuk id=${item.id}:`, updateErr.message);
                    } else {
                        console.log(`[✔ SUKSES] Pesan WA terkirim ke ${item.target_number}`);
                    }
                } else {
                    const errText = await response.text().catch(()=>'No body');
                    console.log(`[✖ GAGAL] Response WA: ${response.status} - ${errText}`);
                    const { error: failErr } = await supabase
                        .from('whatsapp_queue')
                        .update({ status: 'failed', error_message: `HTTP ${response.status}: ${errText}`, retry_count: (item.retry_count || 0) + 1, updated_at: new Date().toISOString() })
                        .eq('id', item.id);
                    if (failErr) console.error(`[✖ UPDATE GAGAL] id=${item.id}:`, failErr.message);
                }

                // -----------------------------------------------------
                // FITUR ANTI-BANNED (JEDA PENGIRIMAN MANUSIAWI)
                // -----------------------------------------------------
                // Acak delay antara 2 sampai 5 detik per satu siklus pengiriman 
                const randomSleep = Math.floor(Math.random() * (5000 - 2000 + 1)) + 2000;
                console.log(`[⏳ JEDA] Beristirahat ${randomSleep/1000} detik meniru ketikan manusia...`);
                await new Promise(resolve => setTimeout(resolve, randomSleep));

            } catch (err) {
                console.log(`[✖ ERROR JARINGAN]`, err.message);
                const { error: netErr } = await supabase
                    .from('whatsapp_queue')
                    .update({ status: 'failed', error_message: err.message, retry_count: (item.retry_count || 0) + 1, updated_at: new Date().toISOString() })
                    .eq('id', item.id);
                if (netErr) console.error(`[✖ UPDATE GAGAL] id=${item.id}:`, netErr.message);
            }
        }
    } catch(err) {
        console.error('CRITICAL DAEMON ERROR:', err.message);
    }
}

// Looping tanpa henti setiap 5 detik!
setInterval(processQueue, 5000);
// Jalankan langsung tanpa menunggu 5 detik pertama
processQueue();
