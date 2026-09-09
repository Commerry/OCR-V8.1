import chokidar from 'chokidar';
import { spawn } from 'child_process';
import Redis from 'ioredis';
import moment from './utils/moment';
import processManager from './utils/processManager';

import socketLog from './utils/socketLog';
import { getConfig } from './utils/getConfig';

const pythonProcessList = {};
const lastConfigUpdated = {};

// Live telemetry per camera, fed by redis messages. Consumed by the web UI
// (socket.io) and by the central-server reporter.
const telemetry = {};
const recentReads = []; // ring buffer of final OCR results (values sent to PLC)
const MAX_RECENT_READS = 100;
// Each read carries the frame it was read from. Images are the heavy part of a
// heartbeat, so only the newest ones keep theirs.
const MAX_READS_WITH_IMAGE = 20;

const getCameraTelemetry = (cameraName) => {
  if (!telemetry[cameraName]) {
    telemetry[cameraName] = {
      lastRead: null, // { value, confidence, at }
      weight: null,
      plcConnected: null,
      lastImage: null, // webp base64 of last read frame
      lastImageAt: null,
      pendingImage: null, // frame of the read that is about to be published
    };
  }
  return telemetry[cameraName];
};

const getTelemetry = () => telemetry;

const getRecentReads = () => recentReads.slice();

const clearRecentReads = (count) => {
  recentReads.splice(0, count);
};

const getCameraStatus = () => {
  const status = {};
  Object.keys(pythonProcessList).forEach((cameraName) => {
    const entry = pythonProcessList[cameraName];
    status[cameraName] = {
      // a process killed by signal has exitCode null but signalCode set
      running: entry.process.exitCode === null && entry.process.signalCode === null,
      started: !!entry.isStarted,
      startTime: entry.startTime ? entry.startTime.toISOString() : null,
    };
  });
  return status;
};

const pythonExe = process.env.NODE_ENV === 'production' ? process.env.PYTHON_EXE_PRODUCTION : process.env.PYTHON_EXE_DEVELOPMENT || 'python';

let config = getConfig();

const killCamera = (io, cameraName) => {
  if (pythonProcessList[cameraName]) {
    pythonProcessList[cameraName].process.kill();
  }

  if (lastConfigUpdated[cameraName]) {
    delete lastConfigUpdated[cameraName];
  }

  const isFound = processManager.killProcessByCameraName(cameraName);
  if (isFound) {
    socketLog(cameraName, io, 'killed');
  }
};


const startCamera = (io, cameraConfig) => {
  const cameraName = cameraConfig.cameraName;
  killCamera(io, cameraName);
  lastConfigUpdated[cameraConfig.cameraName] = cameraConfig.updatedAt;
  try {
    socketLog(cameraName, io, 'starting python process');
    console.log(`[DEBUG] Camera: ${cameraName}, enablePlc: ${cameraConfig.enablePlc}, plcAddress: ${cameraConfig.plcAddress}`);
    const pythonProcess = spawn(pythonExe, ['main.py'], {
      cwd: 'python',
      // shell: true,
      detached: true,
      env: {
        ...process.env,
        ...cameraConfig,
      },
    });

    // save pid
    processManager.savePId(cameraName, pythonProcess.pid);

    pythonProcessList[cameraName] = {
      process: pythonProcess,
      startTime: moment(),
    };

    pythonProcess.on('error', (err) => {
      console.log('process error', err);
    });

    pythonProcess.stdout.on('data', (data) => {
      console.log('stdout: ' + data);
    });

    pythonProcess.stderr.on('data', (data) => {
      console.log('stderr: ' + data);
    });

    pythonProcess.on('close', (code) => {
      console.log('child process exited with code ' + code);
    });

    pythonProcess.stdout.on('data', async (message) => {
      const data = message.toString().trim();
      socketLog(cameraName, io, data);
    });

    pythonProcess.stderr.on('data', async (message) => {
      const data = message.toString().trim();
      socketLog(cameraName, io, data);
    });

    pythonProcess.on('error', (err) => {
      socketLog(cameraName, io, err);
    });

    pythonProcess.on('close', () => {
      socketLog(cameraName, io, 'close');
    });

    pythonProcess.on('exit', () => {
      delete pythonProcessList[cameraName];
      socketLog(cameraName, io, 'exit');
    });
  } catch (e) {
    console.info(e);
  }
};
const processMonitor = (io) => {
  const cameraList = config.cameraList;

  // clear un-use camera
  Object.keys(pythonProcessList).forEach((cameraName) => {
    if (!cameraList[cameraName]) {
      socketLog(cameraName, io, 'kill process by unuse');
      killCamera(io, cameraName);
    }
  });

  // remove start timeout camera
  Object.keys(pythonProcessList).forEach((cameraName) => {
    const startTime = pythonProcessList[cameraName].startTime;
    const isStarted = pythonProcessList[cameraName].isStarted;
    if (!isStarted && moment().diff(startTime, 'second') >= 60) {
      socketLog(cameraName, io, 'kill process by timeout');
      killCamera(io, cameraName);
    }
  });

  // remove exited process
  Object.keys(pythonProcessList).forEach((cameraName) => {
    if (pythonProcessList[cameraName].process.exitCode) {
      socketLog(cameraName, io, 'kill process by exit');
      killCamera(io, cameraName);
    }
  });

  // clear disable camera
  Object.values(cameraList).forEach((cameraConfig) => {
    if (cameraConfig.enable === "0" && pythonProcessList[cameraConfig.cameraName]) {
      const cameraName = cameraConfig.cameraName;
      socketLog(cameraName, io, 'kill process by disabled');
      killCamera(io, cameraName);
    }
  });

  // clear updated camera
  Object.values(cameraList).forEach((cameraConfig) => {
    if (
      typeof lastConfigUpdated[cameraConfig.cameraName] !== 'undefined' &&
      cameraConfig.updatedAt !== lastConfigUpdated[cameraConfig.cameraName]
    ) {
      socketLog(cameraConfig.cameraName, io, 'kill process by updated');
      killCamera(io, cameraConfig.cameraName);
    }
  });

  // start new camera
  Object.values(cameraList).forEach((cameraConfig) => {
    if (cameraConfig.enable === "1") {
      if (typeof pythonProcessList[cameraConfig.cameraName] === 'undefined') {
        socketLog(cameraConfig.cameraName, io, 'start new camera');
        startCamera(io, cameraConfig);
      }
    }
  });

  setTimeout(() => {
    processMonitor(io);
  }, 2000);
};

const ocrRunner = (io) => {
  // subscribe frame
  // maxRetriesPerRequest: null -> subscribe keeps waiting for redis instead of
  // rejecting after 20 retries (unhandled rejection would kill the server)
  const subRedis = new Redis({ maxRetriesPerRequest: null });
  subRedis.on('error', (err) => {
    if (err && err.code === 'ECONNREFUSED') return; // redis not up yet - retry quietly
    console.error('redis error:', err.message);
  });
  subRedis.subscribe([
    'ocr_frame', 'ocr_frame_last', 'ocr_read_image', 'plc_status', 'plc_weight', 'ocr_result',
  ]);
  subRedis.on('message', async (channel, message) => {

    if (channel === 'plc_status') {
      console.log("msg", message)
    }

    const messageList = message.toString().split(' ');
    const cameraName = messageList[0];
    if (pythonProcessList[cameraName] && !pythonProcessList[cameraName].isStarted) {
      pythonProcessList[cameraName].isStarted = true;
    }
    const data = messageList[1];

    // keep telemetry up to date for the central-server reporter
    const cameraTelemetry = getCameraTelemetry(cameraName);
    if (channel === 'plc_weight') {
      cameraTelemetry.weight = parseFloat(data);
    } else if (channel === 'plc_status') {
      cameraTelemetry.plcConnected = data === 'CONNECTED_TO_PLC';
    } else if (channel === 'ocr_frame_last') {
      cameraTelemetry.lastImage = data;
      cameraTelemetry.lastImageAt = new Date().toISOString();
    } else if (channel === 'ocr_read_image') {
      // python sends this right before the result it belongs to
      cameraTelemetry.pendingImage = data;
    } else if (channel === 'ocr_result') {
      const at = new Date().toISOString();
      const read = {
        camera: cameraName,
        value: data,
        confidence: messageList[2] ? parseFloat(messageList[2]) : null,
        // weight the PLC reported closest to this read (published every 0.5s)
        weight: typeof cameraTelemetry.weight === 'number' ? cameraTelemetry.weight : null,
        at,
      };
      if (cameraTelemetry.pendingImage) {
        read.image = cameraTelemetry.pendingImage;
        cameraTelemetry.pendingImage = null;
        // the dashboard shows this too, so the preview switch is no longer needed
        cameraTelemetry.lastImage = read.image;
        cameraTelemetry.lastImageAt = at;
      }
      cameraTelemetry.lastRead = { ...read, image: undefined };
      recentReads.push(read);
      if (recentReads.length > MAX_RECENT_READS) {
        recentReads.splice(0, recentReads.length - MAX_RECENT_READS);
      }
      // drop images from all but the newest reads so a backlog stays small
      const withImage = recentReads.filter((entry) => entry.image);
      if (withImage.length > MAX_READS_WITH_IMAGE) {
        withImage.slice(0, withImage.length - MAX_READS_WITH_IMAGE)
          .forEach((entry) => { delete entry.image; });
      }
    }

    io.emit(`${channel}_${cameraName}`, {
      data,
    });
  });

  chokidar.watch('config.json').on('change', () => {
    setTimeout(() => {
      config = getConfig();
    }, 1000);
    console.info('updated');
  });

  processMonitor(io);
};

export default ocrRunner;
export { getTelemetry, getRecentReads, clearRecentReads, getCameraStatus };
