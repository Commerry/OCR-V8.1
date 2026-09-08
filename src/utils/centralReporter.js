import os from 'os';
import { getConfig } from './getConfig';
import { getSystemHealth, getNetworkIdentity } from './systemHealth';
import {
  getTelemetry,
  getRecentReads,
  clearRecentReads,
  getCameraStatus,
} from '../ocrRunner';

/*
 * Central-server reporter (device side).
 *
 * Devices push heartbeats via HTTP POST — no polling, no broker, the central
 * web only needs one endpoint. First heartbeat from an unknown deviceId is how
 * the central auto-registers a new device (deviceId = MAC address).
 *
 * POST {centralUrl}
 * Headers: Content-Type: application/json
 *          X-Api-Key: <apiKey>          (when configured)
 * Body:
 * {
 *   "type": "heartbeat",
 *   "deviceId": "dc:a6:32:aa:bb:cc",           // MAC, stable per device
 *   "sentAt": "2026-07-31T08:00:00.000Z",
 *   "device": {
 *     "hostname": "cm4-line-1",
 *     "ip": "10.31.182.51",
 *     "mac": "dc:a6:32:aa:bb:cc",
 *     "interface": "eth0",
 *     "platform": "linux",
 *     "appVersion": "1.0.0"
 *   },
 *   "cameras": [{
 *     "cameraName": "in",
 *     "enabled": true,                          // switch in web UI
 *     "running": true,                          // python process alive
 *     "started": true,                          // camera produced frames
 *     "plcEnabled": true,
 *     "ocrModel": "29_04",                      // '' = default model
 *     "letterRead": false,                      // A-Z prefix reading on/off
 *     "plcConnected": true,                     // TRUE/FALSE per plc_status
 *     "lastRead": { "value": "123", "confidence": 0.97, "at": "..." },
 *     "weight": 12.345,
 *     "lastImage": "<webp base64>",             // only when includeImage on
 *     "lastImageAt": "..."
 *   }],
 *   "recentReads": [                            // history since last heartbeat
 *     { "camera": "in", "value": "123", "confidence": 0.97, "weight": 12.3, "at": "..." }
 *   ],
 *   "health": {
 *     "platform": "linux", "uptimeSec": 123456,
 *     "cpu": { "cores": 4, "loadPercent": 35 },
 *     "ram": { "totalMb": 3800, "freeMb": 2100 },
 *     "disk": { "totalMb": 61000, "usedMb": 15000, "usedPercent": 25 },
 *     "cpuTempC": 62.3
 *   }
 * }
 *
 * Central should answer 2xx. Anything else is logged and retried on the next
 * interval (recentReads are kept until a heartbeat succeeds, capped at 100).
 */

const DEFAULT_SETTINGS = {
  enabled: false,
  url: '',
  apiKey: '',
  intervalSec: 30,
  includeImage: true,
};

let settings = { ...DEFAULT_SETTINGS };
let timer = null;
let appVersion = '0.0.0';
let lastResult = { ok: null, at: null, status: null, error: null };

try {
  // eslint-disable-next-line global-require
  appVersion = require('../../package.json').version || '0.0.0';
} catch (e) {
  // keep default
}

const buildPayload = async (includeImage) => {
  const config = getConfig();
  const identity = getNetworkIdentity();
  const cameraStatus = getCameraStatus();
  const telemetry = getTelemetry();

  const cameras = Object.values(config.cameraList || {}).map((cameraConfig) => {
    const name = cameraConfig.cameraName;
    const status = cameraStatus[name] || {};
    const cameraTelemetry = telemetry[name] || {};
    const camera = {
      cameraName: name,
      displayName: cameraConfig.displayName || name,
      enabled: cameraConfig.enable === '1',
      running: !!status.running,
      started: !!status.started,
      plcEnabled: cameraConfig.enablePlc === '1',
      // which OCR model produced these reads ('' = the default blob)
      ocrModel: cameraConfig.ocrModel || '',
      letterRead: cameraConfig.enableLetterRead === '1',
      plcConnected: typeof cameraTelemetry.plcConnected === 'boolean' ? cameraTelemetry.plcConnected : null,
      lastRead: cameraTelemetry.lastRead || null,
      weight: typeof cameraTelemetry.weight === 'number' ? cameraTelemetry.weight : null,
    };
    if (includeImage && cameraTelemetry.lastImage) {
      camera.lastImage = cameraTelemetry.lastImage;
      camera.lastImageAt = cameraTelemetry.lastImageAt;
    }
    return camera;
  });

  return {
    type: 'heartbeat',
    deviceId: identity.mac || os.hostname(),
    sentAt: new Date().toISOString(),
    device: {
      hostname: os.hostname(),
      ip: identity.ip,
      mac: identity.mac,
      interface: identity.interface,
      platform: process.platform,
      appVersion,
    },
    cameras,
    recentReads: getRecentReads(),
    health: await getSystemHealth(),
  };
};

const sendHeartbeat = async (overrideSettings) => {
  const active = overrideSettings || settings;
  if (!active.url) {
    return { ok: false, status: null, error: 'no central URL configured' };
  }

  const payload = await buildPayload(active.includeImage);
  const readCount = payload.recentReads.length;

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 8000);
  try {
    const headers = { 'Content-Type': 'application/json' };
    if (active.apiKey) {
      headers['X-Api-Key'] = active.apiKey;
    }
    const response = await fetch(active.url, {
      method: 'POST',
      headers,
      body: JSON.stringify(payload),
      signal: controller.signal,
    });
    const ok = response.status >= 200 && response.status < 300;
    if (ok) {
      // reads delivered - drop them from the buffer
      clearRecentReads(readCount);
    }
    lastResult = { ok, at: new Date().toISOString(), status: response.status, error: null };
    return lastResult;
  } catch (error) {
    lastResult = {
      ok: false,
      at: new Date().toISOString(),
      status: null,
      error: error.name === 'AbortError' ? 'timeout' : error.message,
    };
    return lastResult;
  } finally {
    clearTimeout(timeout);
  }
};

const tick = async () => {
  if (!settings.enabled || !settings.url) return;
  const result = await sendHeartbeat();
  if (!result.ok) {
    console.warn(`central reporter: heartbeat failed (${result.error || result.status})`);
  }
};

const applySchedule = () => {
  if (timer) {
    clearInterval(timer);
    timer = null;
  }
  if (settings.enabled && settings.url) {
    const intervalMs = Math.max(5, settings.intervalSec || 30) * 1000;
    timer = setInterval(tick, intervalMs);
    // send one right away so the central sees the device without waiting
    tick();
  }
};

const updateSettings = (next) => {
  settings = { ...DEFAULT_SETTINGS, ...(next || {}) };
  settings.intervalSec = parseInt(settings.intervalSec, 10) || 30;
  applySchedule();
};

const getSettings = () => ({ ...settings });

const getLastResult = () => ({ ...lastResult });

const start = () => {
  const config = getConfig();
  updateSettings(config.central);
};

export default {
  start,
  updateSettings,
  getSettings,
  getLastResult,
  sendHeartbeat,
};
