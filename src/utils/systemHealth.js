import fs from 'fs';
import os from 'os';
import path from 'path';
import { exec } from 'child_process';

const execAsync = (cmd) =>
  new Promise((resolve) => {
    exec(cmd, { timeout: 5000 }, (err, stdout) => resolve(err ? null : stdout));
  });

// Snapshot of device health: disk / CPU / RAM / temperature / uptime.
// Used by GET /api/system/health and by the central-server reporter.
const getSystemHealth = async () => {
  const health = {
    platform: process.platform,
    uptimeSec: Math.round(os.uptime()),
    cpu: { cores: os.cpus().length, loadPercent: null },
    ram: {
      totalMb: Math.round(os.totalmem() / 1024 / 1024),
      freeMb: Math.round(os.freemem() / 1024 / 1024),
    },
    disk: null,
    cpuTempC: null,
  };

  // CPU load: 1-min load average vs core count (meaningful on Linux/CM4)
  const load = os.loadavg()[0];
  if (load > 0) {
    health.cpu.loadPercent = Math.min(100, Math.round((load / health.cpu.cores) * 100));
  }

  if (process.platform === 'linux') {
    // Disk usage of the filesystem holding image storage
    const df = await execAsync("df -kP / | tail -1 | awk '{print $2, $3, $5}'");
    if (df) {
      const [totalK, usedK, usedPercent] = df.trim().split(/\s+/);
      health.disk = {
        totalMb: Math.round(parseInt(totalK, 10) / 1024),
        usedMb: Math.round(parseInt(usedK, 10) / 1024),
        usedPercent: parseInt(usedPercent, 10),
      };
    }

    // SoC temperature (Raspberry Pi CM4)
    try {
      const raw = fs.readFileSync('/sys/class/thermal/thermal_zone0/temp', 'utf8');
      health.cpuTempC = Math.round(parseInt(raw.trim(), 10) / 100) / 10;
    } catch (err) {
      // sensor not available
    }
  } else if (process.platform === 'win32') {
    // Dev machine fallback: disk usage of the current drive
    const drive = path.parse(process.cwd()).root.replace('\\', '');
    const out = await execAsync(
      `powershell -NoProfile -Command "$d = Get-PSDrive ${drive.replace(':', '')}; Write-Output ('' + $d.Used + ' ' + $d.Free)"`
    );
    if (out) {
      const [used, free] = out.trim().split(/\s+/).map(Number);
      if (used && free) {
        const totalMb = Math.round((used + free) / 1024 / 1024);
        const usedMb = Math.round(used / 1024 / 1024);
        health.disk = {
          totalMb,
          usedMb,
          usedPercent: Math.round((usedMb / totalMb) * 100),
        };
      }
    }
  }

  return health;
};

// Primary network interface info: prefer real NICs (eth/en/wlan) with a real MAC
const getNetworkIdentity = () => {
  const interfaces = os.networkInterfaces();
  const candidates = [];
  for (const name of Object.keys(interfaces)) {
    for (const iface of interfaces[name]) {
      if (iface.family === 'IPv4' && !iface.internal && iface.mac !== '00:00:00:00:00:00') {
        candidates.push({ interface: name, ip: iface.address, mac: iface.mac });
      }
    }
  }
  const preferred = candidates.find((c) => /^(eth|en|wlan|wl)/i.test(c.interface));
  return preferred || candidates[0] || { interface: null, ip: null, mac: null };
};

export { getSystemHealth, getNetworkIdentity };
