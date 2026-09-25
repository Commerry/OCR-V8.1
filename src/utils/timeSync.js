import { execFile } from 'child_process';

/*
 * Keeps the device clock right, using the central server as the reference.
 *
 * A CM4 has no RTC battery: after a power cut it comes back with whatever time
 * was last written to disk, often weeks out. Everything the camera records is
 * stamped with that clock, so the central files those reads under the wrong
 * day and reports for the current week come back empty while the camera is
 * working perfectly.
 *
 * The central answers every heartbeat with its own time, so the first reply
 * after a reboot - or any reply at all - is enough to correct the device. No
 * NTP server needed, which matters here because the cameras cannot reach one
 * through the factory proxy.
 *
 * Setting the clock needs root, granted for these commands only by
 * /etc/sudoers.d/ocr-settime (installed by install.sh / update.sh).
 */

// below this the difference is just network latency, not a wrong clock
const TOLERANCE_MS = 5000;
// a jump this large is worth shouting about: it means the device rebooted
// with a dead clock rather than drifting
const NOTABLE_MS = 2 * 60 * 1000;

let state = {
  lastSyncAt: null,     // when we last changed the clock
  lastDriftMs: null,    // how far off the device was at that moment
  lastCheckedAt: null,
  syncCount: 0,
  lastError: null,
  timeZone: null,
};

const run = (file, args) => new Promise((resolve) => {
  execFile(file, args, { timeout: 10000 }, (error, stdout, stderr) => {
    resolve({
      ok: !error,
      out: String(stdout || '').trim(),
      err: error ? (error.message || String(stderr || '')).trim() : '',
    });
  });
});

/** Is the device clock far enough from the server's to be worth correcting? */
const driftMs = (serverTimeIso, now = Date.now()) => {
  const server = Date.parse(serverTimeIso);
  if (!Number.isFinite(server)) return null;
  return server - now;
};

const needsSync = (drift) => drift !== null && Math.abs(drift) > TOLERANCE_MS;

/**
 * Apply the server's time to this device.
 * Sets UTC explicitly, so the device timezone cannot skew the result - a
 * camera left on UTC used to end up seven hours ahead when given local time.
 */
const applyTime = async (serverTimeIso, wantedZone) => {
  const utc = new Date(serverTimeIso).toISOString().replace(/\.\d{3}Z$/, 'Z');

  if (wantedZone) {
    const current = await run('sudo', ['-n', 'timedatectl', 'show', '-p', 'Timezone', '--value']);
    if (current.ok && current.out && current.out !== wantedZone) {
      await run('sudo', ['-n', 'timedatectl', 'set-timezone', wantedZone]);
      state.timeZone = wantedZone;
    } else if (current.ok) {
      state.timeZone = current.out || null;
    }
  }

  // NTP would fight us for the clock, and it cannot reach a server here anyway
  await run('sudo', ['-n', 'timedatectl', 'set-ntp', 'false']);

  let result = await run('sudo', ['-n', 'date', '-u', '-s', utc]);
  if (!result.ok) {
    // some images ship timedatectl but a busybox date that rejects -s
    result = await run('sudo', ['-n', 'timedatectl', 'set-time', utc.replace('T', ' ').replace('Z', '')]);
  }
  if (!result.ok) return { ok: false, error: result.err || 'set time failed' };

  // survive the next power cut: a real RTC if there is one, the file-backed
  // fake clock otherwise (Raspberry Pi OS ships fake-hwclock)
  await run('sudo', ['-n', 'hwclock', '-w']);
  await run('sudo', ['-n', 'fake-hwclock', 'save']);
  return { ok: true };
};

/**
 * Called with whatever the central answered. Corrects the clock when needed.
 * Safe to call on every heartbeat - it does nothing while the clock is right.
 */
const syncFromServer = async (serverTimeIso, wantedZone) => {
  state.lastCheckedAt = new Date().toISOString();
  const drift = driftMs(serverTimeIso);
  if (!needsSync(drift)) {
    state.lastDriftMs = drift;
    return { changed: false, driftMs: drift };
  }

  const before = new Date().toISOString();
  const applied = await applyTime(serverTimeIso, wantedZone);
  if (!applied.ok) {
    state.lastError = applied.error;
    console.warn(`timeSync: ต้องปรับเวลา ${Math.round(drift / 1000)} วิ แต่ตั้งไม่สำเร็จ (${applied.error})`);
    return { changed: false, driftMs: drift, error: applied.error };
  }

  state.lastSyncAt = new Date().toISOString();
  state.lastDriftMs = drift;
  state.syncCount += 1;
  state.lastError = null;

  const seconds = Math.round(drift / 1000);
  const message = `timeSync: ตั้งนาฬิกาใหม่จากเวลาเซิร์ฟเวอร์ (${before} -> ${state.lastSyncAt}, ต่าง ${seconds} วินาที)`;
  if (Math.abs(drift) > NOTABLE_MS) console.warn(`${message} - เครื่องน่าจะเพิ่งรีบูตโดยไม่มี RTC`);
  else console.log(message);

  return { changed: true, driftMs: drift, at: state.lastSyncAt };
};

const getState = () => ({ ...state, toleranceMs: TOLERANCE_MS });

const resetState = () => {
  state = {
    lastSyncAt: null, lastDriftMs: null, lastCheckedAt: null,
    syncCount: 0, lastError: null, timeZone: null,
  };
};

export default { syncFromServer, getState };
export { syncFromServer, getState, driftMs, needsSync, resetState, TOLERANCE_MS };
