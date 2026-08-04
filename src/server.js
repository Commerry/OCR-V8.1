import 'dotenv/config';
import express from 'express';
import bodyParser from 'body-parser';
import cors from 'cors';
import fs from 'fs';
import http from 'http';
import path from 'path';
import archiver from 'archiver';
import multer from 'multer';
import { spawn, exec } from 'child_process';
import os from 'os';
import createSocketServer from './utils/socket';
import ocrRunner from './ocrRunner';
import { getConfig, saveConfig } from './utils/getConfig';
import processManager from './utils/processManager';
import AuthManager from './auth/AuthManager';
import NetworkManager from './utils/network/NetworkManager';
import { getSystemHealth } from './utils/systemHealth';
import centralReporter from './utils/centralReporter';

// Try to import HTML files, fallback to reading from filesystem
let indexhtml;
let loginhtml;
try {
  // eslint-disable-next-line import/no-unresolved
  indexhtml = require('./index.html');
  // eslint-disable-next-line import/no-unresolved
  loginhtml = require('./login.html');
} catch (err) {
  // Fallback to reading files directly
  try {
    indexhtml = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
    loginhtml = fs.readFileSync(path.join(__dirname, 'login.html'), 'utf8');
  } catch (readErr) {
    // eslint-disable-next-line no-console
    console.error('Failed to load HTML files:', readErr);
    process.exit(1);
  }
}

processManager.killAll();

const app = express();
app.use(
  cors({
    origin: (origin, callback) => {
      callback(null, true);
    },
    credentials: true,
  }),
);

// Simple cookie parser function
const parseCookies = (cookieHeader) => {
  const cookies = {};
  if (cookieHeader) {
    cookieHeader.split(';').forEach((cookie) => {
      const parts = cookie.trim().split('=');
      if (parts.length === 2) {
        cookies[parts[0]] = parts[1];
      }
    });
  }
  return cookies;
};

app.use(bodyParser.urlencoded({ extended: true }));
app.use(bodyParser.json());
app.use('/public', express.static('./public'));
app.use('/Img', express.static('./Img'));
// Serve images from writeFilePath config dynamically
app.use('/ImgData', (req, res, next) => {
  const cfg = getConfig();
  const writePath = cfg?.cameraList ? Object.values(cfg.cameraList)[0]?.writeFilePath : null;
  if (writePath) {
    express.static(writePath)(req, res, next);
  } else {
    next();
  }
});

const server = http.createServer(app);
const io = createSocketServer(server);

const config = getConfig();

// Enhanced auth middleware
const requireAuth = (req, res, next) => {
  const cookies = parseCookies(req.headers.cookie);
  const sessionId = cookies.sessionId;
  const session = AuthManager.validateSession(sessionId);
  if (session) {
    req.user = session;
    return next();
  }
  return res.redirect('/login');
};

const renderIndex = (cameraName, userRole = 'admin', user = null) => {
  const currentState = {
    selectedCameraName: cameraName,
    userRole,
    user,
    ...config,
  };
  let html = indexhtml.toString();
  html = html.replace(
    'const state = {}',
    `const state = ${JSON.stringify(currentState)}`,
  );
  return html;
};

// Login page
app.get('/login', (req, res) => {
  res.send(loginhtml.toString());
});

// Login handler
app.post('/login', (req, res) => {
  const { username, password } = req.body;
  
  const authResult = AuthManager.authenticate(username, password);
  
  if (authResult.success) {
    const sessionId = AuthManager.createSession(authResult.user);
    
    res.setHeader(
      'Set-Cookie',
      `sessionId=${sessionId}; Max-Age=${24 * 60 * 60}; Path=/; HttpOnly`,
    );
    res.json({ success: true, sessionId, user: authResult.user });
  } else {
    res.json({ success: false, message: authResult.message });
  }
});

// Logout handler
app.post('/logout', (req, res) => {
  const cookies = parseCookies(req.headers.cookie);
  const sessionId = cookies.sessionId;
  if (sessionId) {
    AuthManager.removeSession(sessionId);
  }
  res.setHeader('Set-Cookie', 'sessionId=; Max-Age=0; Path=/');
  res.json({ success: true });
});

// Network configuration endpoints
app.get('/api/network/current', requireAuth, async (req, res) => {
  try {
    const config = await NetworkManager.getCurrentConfig();
    res.json({ success: true, config });
  } catch (error) {
    res.status(500).json({
      success: false,
      message: 'Failed to get network configuration',
    });
  }
});

app.get('/api/system/health', requireAuth, async (req, res) => {
  const health = await getSystemHealth();
  res.json({ success: true, health });
});

// ---- Central server reporter ----
app.get('/api/system/central', requireAuth, (req, res) => {
  // settings include the API key - admin only
  if (req.user.role !== 'admin') {
    return res.status(403).json({ success: false, message: 'Access denied' });
  }
  return res.json({
    success: true,
    central: centralReporter.getSettings(),
    lastResult: centralReporter.getLastResult(),
  });
});

app.post('/api/system/central', requireAuth, (req, res) => {
  if (req.user.role !== 'admin') {
    return res.status(403).json({ success: false, message: 'Access denied' });
  }
  const { enabled, url, apiKey, intervalSec, includeImage } = req.body || {};
  const central = {
    enabled: !!enabled,
    url: (url || '').trim(),
    apiKey: (apiKey || '').trim(),
    intervalSec: parseInt(intervalSec, 10) || 30,
    includeImage: !!includeImage,
  };
  if (central.enabled && !central.url) {
    return res.json({ success: false, message: 'Central URL is required' });
  }
  config.central = central;
  saveConfig(config);
  centralReporter.updateSettings(central);
  return res.json({ success: true, central });
});

app.post('/api/system/central/test', requireAuth, async (req, res) => {
  if (req.user.role !== 'admin') {
    return res.status(403).json({ success: false, message: 'Access denied' });
  }
  const { url, apiKey, includeImage } = req.body || {};
  const result = await centralReporter.sendHeartbeat({
    url: (url || '').trim(),
    apiKey: (apiKey || '').trim(),
    includeImage: !!includeImage,
  });
  return res.json({ success: result.ok, result });
});

// ---- Rename camera (display name only) ----
// Sets displayName without touching cameraName (internal id used for files,
// redis channels, PLC) and without bumping updatedAt - so the camera process
// does NOT restart. The UI shows displayName everywhere.
app.post('/api/system/rename-camera', requireAuth, (req, res) => {
  if (req.user.role !== 'admin') {
    return res.status(403).json({ success: false, message: 'Access denied' });
  }
  const { cameraName, displayName } = req.body || {};
  const target = config.cameraList[cameraName];
  if (!target) {
    return res.json({ success: false, message: 'Camera not found' });
  }
  const clean = (displayName || '').trim();
  if (!clean || clean.length > 40) {
    return res.json({ success: false, message: 'Name must be 1-40 characters' });
  }
  target.displayName = clean;
  saveConfig(config);
  return res.json({ success: true, displayName: clean });
});

app.get('/api/system/models', requireAuth, (req, res) => {
  try {
    const modelsDir = path.join(__dirname, '..', 'python', 'models');
    const models = fs
      .readdirSync(modelsDir, { withFileTypes: true })
      .filter(
        (entry) =>
          entry.isDirectory() &&
          fs.existsSync(path.join(modelsDir, entry.name, 'best_model.blob')) &&
          fs.existsSync(path.join(modelsDir, entry.name, 'metadata.json'))
      )
      .map((entry) => entry.name)
      .sort();
    res.json({ success: true, models });
  } catch (error) {
    res.json({ success: false, models: [], error: error.message });
  }
});

app.post('/api/network/configure', requireAuth, async (req, res) => {
  // Only admin can configure network
  if (req.user.role !== 'admin') {
    return res.status(403).json({ success: false, message: 'Access denied' });
  }

  try {
    console.log('Network configuration request:', req.body);
    const result = await NetworkManager.configureNetwork(req.body);
    console.log('Network configuration result:', result);
    res.json(result);
  } catch (error) {
    console.error('Network configuration error:', error);
    res.status(500).json({
      success: false,
      message: error.message || 'Failed to update network configuration',
    });
  }
});

// Get network interfaces
app.get('/api/network/interfaces', requireAuth, async (req, res) => {
  try {
    console.log('Getting network interfaces...');
    await NetworkManager.init(); // Ensure initialization
    const interfaces = await NetworkManager.getNetworkInterfaces();
    const systemType = NetworkManager.networkType;
    
    console.log('Network interfaces response:', {
      interfaces,
      systemType,
      primaryInterface: NetworkManager.interfaceName
    });
    
    res.json({ 
      success: true, 
      interfaces, 
      systemType,
      primaryInterface: NetworkManager.interfaceName 
    });
  } catch (error) {
    console.error('Error getting network interfaces:', error);
    res.status(500).json({
      success: false,
      message: 'Failed to get network interfaces: ' + error.message,
    });
  }
});

// Test network connectivity
app.post('/api/network/test', requireAuth, async (req, res) => {
  try {
    const { host } = req.body;
    const result = await NetworkManager.testConnectivity(host || '8.8.8.8');
    res.json(result);
  } catch (error) {
    res.status(500).json({
      success: false,
      message: 'Failed to test connectivity',
    });
  }
});

// Get network system info
app.get('/api/network/info', requireAuth, async (req, res) => {
  try {
    await NetworkManager.init(); // Ensure detection is complete
    
    const info = {
      systemType: NetworkManager.networkType,
      primaryInterface: NetworkManager.interfaceName,
      configPaths: {
        netplan: '/etc/netplan/',
        interfaces: '/etc/network/interfaces',
        ifcfg: '/etc/sysconfig/network-scripts/',
        networkmanager: '/etc/NetworkManager/'
      }
    };
    
    res.json({ success: true, info });
  } catch (error) {
    res.status(500).json({
      success: false,
      message: 'Failed to get network system info',
    });
  }
});

// User management endpoints (admin only)
app.get('/api/users', requireAuth, (req, res) => {
  if (req.user.role !== 'admin') {
    return res.status(403).json({ success: false, message: 'Access denied' });
  }
  
  const users = AuthManager.listUsers();
  res.json({ success: true, users });
});

// Get single user
app.get('/api/users/:username', requireAuth, (req, res) => {
  if (req.user.role !== 'admin') {
    return res.status(403).json({ success: false, message: 'Access denied' });
  }
  
  const users = AuthManager.listUsers();
  const user = users.find((u) => u.username === req.params.username);
  
  if (user) {
    return res.json({ success: true, user });
  }
  return res.status(404).json({ success: false, message: 'User not found' });
});

// Create user - both endpoints for compatibility
app.post('/api/users', requireAuth, (req, res) => {
  if (req.user.role !== 'admin') {
    return res.status(403).json({ success: false, message: 'Access denied' });
  }
  
  const result = AuthManager.addUser(req.body);
  if (result.success) {
    return res.json(result);
  }
  return res.status(400).json(result);
});

app.post('/api/users/create', requireAuth, (req, res) => {
  if (req.user.role !== 'admin') {
    return res.status(403).json({ success: false, message: 'Access denied' });
  }
  
  const result = AuthManager.addUser(req.body);
  if (result.success) {
    return res.json(result);
  }
  return res.status(400).json(result);
});

app.put('/api/users/:username', requireAuth, (req, res) => {
  if (req.user.role !== 'admin') {
    return res.status(403).json({ success: false, message: 'Access denied' });
  }
  
  const result = AuthManager.updateUser(req.params.username, req.body);
  if (result.success) {
    return res.json(result);
  }
  return res.status(400).json(result);
});

app.delete('/api/users/:username', requireAuth, (req, res) => {
  if (req.user.role !== 'admin') {
    return res.status(403).json({ success: false, message: 'Access denied' });
  }
  
  const result = AuthManager.deleteUser(req.params.username);
  if (result.success) {
    return res.json(result);
  }
  return res.status(400).json(result);
});

// Alternative delete endpoint for compatibility
app.delete('/api/users/delete/:username', requireAuth, (req, res) => {
  if (req.user.role !== 'admin') {
    return res.status(403).json({ success: false, message: 'Access denied' });
  }
  
  const result = AuthManager.deleteUser(req.params.username);
  if (result.success) {
    return res.json(result);
  }
  return res.status(400).json(result);
});

// Alternative update endpoint for compatibility
app.put('/api/users/update/:username', requireAuth, (req, res) => {
  if (req.user.role !== 'admin') {
    return res.status(403).json({ success: false, message: 'Access denied' });
  }
  
  const result = AuthManager.updateUser(req.params.username, req.body);
  if (result.success) {
    return res.json(result);
  }
  return res.status(400).json(result);
});

// Gallery API endpoint - List images from Img folder
app.get('/api/gallery/images', requireAuth, (req, res) => {
  try {
    const cfg = getConfig();
    const writePath = cfg?.cameraList ? Object.values(cfg.cameraList)[0]?.writeFilePath : null;
    const imgDir = writePath || path.join(__dirname, '..', 'Img');
    
    // Check if directory exists
    if (!fs.existsSync(imgDir)) {
      console.info('Img directory does not exist, creating it...');
      fs.mkdirSync(imgDir, { recursive: true });
      return res.json({ success: true, images: [] });
    }
    
    // Read directory
    const files = fs.readdirSync(imgDir);
    
    // Filter for image files and get stats
    const images = files
      .filter(file => {
        const ext = path.extname(file).toLowerCase();
        return ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp'].includes(ext);
      })
      .map(file => {
        const filePath = path.join(imgDir, file);
        const stats = fs.statSync(filePath);
        return {
          name: file,
          path: `/ImgData/${file}`,
          size: stats.size,
          modified: stats.mtime,
        };
      })
      .sort((a, b) => b.modified - a.modified); // Sort by most recent first
    
    res.json({ success: true, images, imgDir });
  } catch (error) {
    console.error('Error reading gallery images:', error);
    res.status(500).json({
      success: false,
      error: error.message || 'Failed to read images',
    });
  }
});

// Export gallery images as ZIP
app.get('/api/gallery/export', requireAuth, (req, res) => {
  try {
    const cfg = getConfig();
    const writePath = cfg?.cameraList ? Object.values(cfg.cameraList)[0]?.writeFilePath : null;
    const imgDir = writePath || path.join(__dirname, '..', 'Img');
    const daysParam = req.query.days;
    const days = daysParam !== undefined && daysParam !== '' ? parseInt(daysParam) : 0;
    
    if (!fs.existsSync(imgDir)) {
      return res.status(404).json({
        success: false,
        error: 'Image directory not found',
      });
    }
    
    // Filter by date if days > 0
    const cutoffTime = days > 0 ? Date.now() - days * 24 * 60 * 60 * 1000 : 0;

    // Get all image files
    const files = fs.readdirSync(imgDir).filter(file => {
      const ext = path.extname(file).toLowerCase();
      if (!['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp'].includes(ext)) return false;
      if (days > 0) {
        const stat = fs.statSync(path.join(imgDir, file));
        return stat.mtimeMs >= cutoffTime;
      }
      return true;
    });
    
    if (files.length === 0) {
      return res.status(404).json({
        success: false,
        error: 'No images found to export',
      });
    }
    
    // Set response headers for ZIP download
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, -5);
    res.setHeader('Content-Type', 'application/zip');
    res.setHeader('Content-Disposition', `attachment; filename="ocr-images-${timestamp}.zip"`);
    
    // Create ZIP archive
    const archive = archiver('zip', {
      zlib: { level: 6 } // Compression level (0-9)
    });
    
    // Handle errors
    archive.on('error', (err) => {
      console.error('Archive error:', err);
      res.status(500).json({ success: false, error: 'Failed to create ZIP file' });
    });
    
    // Pipe archive to response
    archive.pipe(res);
    
    // Add files to archive
    files.forEach(file => {
      const filePath = path.join(imgDir, file);
      archive.file(filePath, { name: file });
    });
    
    // Finalize the archive
    archive.finalize();
    
  } catch (error) {
    console.error('Error exporting gallery:', error);
    res.status(500).json({
      success: false,
      error: error.message || 'Failed to export images',
    });
  }
});

// Delete old images (keep only recent ones)
app.post('/api/gallery/cleanup', requireAuth, (req, res) => {
  // destructive - admin only
  if (req.user.role !== 'admin') {
    return res.status(403).json({ success: false, message: 'Access denied' });
  }
  try {
    const cfg = getConfig();
    const writePath = cfg?.cameraList ? Object.values(cfg.cameraList)[0]?.writeFilePath : null;
    const imgDir = writePath || path.join(__dirname, '..', 'Img');
    const { keepDays = 7 } = req.body; // Default keep 7 days
    
    if (!fs.existsSync(imgDir)) {
      return res.json({ success: true, deletedCount: 0 });
    }
    
    const files = fs.readdirSync(imgDir);
    const cutoffDate = new Date();
    cutoffDate.setDate(cutoffDate.getDate() - keepDays);
    
    let deletedCount = 0;
    
    files.forEach(file => {
      const ext = path.extname(file).toLowerCase();
      if (['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp'].includes(ext)) {
        const filePath = path.join(imgDir, file);
        const stats = fs.statSync(filePath);
        
        if (stats.mtime < cutoffDate) {
          fs.unlinkSync(filePath);
          deletedCount++;
        }
      }
    });
    
    res.json({ 
      success: true, 
      deletedCount,
      message: `Deleted ${deletedCount} images older than ${keepDays} days`
    });
    
  } catch (error) {
    console.error('Error cleaning up gallery:', error);
    res.status(500).json({
      success: false,
      error: error.message || 'Failed to cleanup images',
    });
  }
});

// OCR Test Tool API - Admin only
// Setup multer for file uploads
const upload = multer({
  storage: multer.memoryStorage(),
  limits: {
    fileSize: 10 * 1024 * 1024, // 10MB limit
  },
  fileFilter: (req, file, cb) => {
    // Accept only image files
    if (file.mimetype.startsWith('image/')) {
      cb(null, true);
    } else {
      cb(new Error('Only image files are allowed'), false);
    }
  }
});

app.post('/api/ocr/test', requireAuth, upload.single('image'), async (req, res) => {
  // Only admin can use OCR test tool
  if (req.user.role !== 'admin') {
    return res.status(403).json({ success: false, error: 'Access denied' });
  }

  if (!req.file) {
    return res.status(400).json({ success: false, error: 'No image file provided' });
  }

  try {
    // Save image temporarily
    const tempDir = path.join(__dirname, '..', 'temp');
    if (!fs.existsSync(tempDir)) {
      fs.mkdirSync(tempDir, { recursive: true });
    }

    const tempFilePath = path.join(tempDir, `test_${Date.now()}_${req.file.originalname}`);
    fs.writeFileSync(tempFilePath, req.file.buffer);

    // Call Python script to process the image
    // cwd must be set to python/ so that `utils` module is resolvable
    const pythonDir = path.join(__dirname, '..', 'python');
    const pythonScript = path.join(pythonDir, 'utils', 'ocr_test.py');
    const absImagePath = path.resolve(tempFilePath);
    
    const pythonProcess = spawn('python', [pythonScript, absImagePath], {
      cwd: pythonDir,
    });

    let outputData = '';
    let errorData = '';

    pythonProcess.stdout.on('data', (data) => {
      outputData += data.toString();
    });

    pythonProcess.stderr.on('data', (data) => {
      errorData += data.toString();
    });

    pythonProcess.on('close', (code) => {
      // Clean up temp file
      try {
        fs.unlinkSync(tempFilePath);
      } catch (err) {
        console.error('Error removing temp file:', err);
      }

      if (code !== 0) {
        console.error('Python script error:', errorData);
        return res.status(500).json({
          success: false,
          error: 'OCR processing failed: ' + errorData
        });
      }

      try {
        const result = JSON.parse(outputData);
        res.json(result);
      } catch (parseError) {
        console.error('Error parsing Python output:', parseError);
        console.error('Output was:', outputData);
        res.status(500).json({
          success: false,
          error: 'Failed to parse OCR result'
        });
      }
    });

  } catch (error) {
    console.error('Error in OCR test:', error);
    res.status(500).json({
      success: false,
      error: error.message || 'Failed to process image'
    });
  }
});

app.all('/', requireAuth, (req, res) => {
  let cameraName = '';
  if (req.method === 'POST') {
    // only admins may change camera config (UI already disables the form for users)
    if (req.user.role !== 'admin') {
      return res.status(403).send('Access denied');
    }
    const body = req.body || {};
    body.enable = body.enable === 'on' ? '1' : '0';
    body.enableOcr = body.enableOcr === 'on' ? '1' : '0';
    body.enablePreview = body.enablePreview === 'on' ? '1' : '0';
    body.enablePlc = body.enablePlc === 'on' ? '1' : '0';
    body.enableWriteFile = body.enableWriteFile === 'on' ? '1' : '0';
    body.saveOnlyValid = body.saveOnlyValid === 'on' ? '1' : '0';
    body.enableLetterRead = body.enableLetterRead === 'on' ? '1' : '0';
    cameraName = body.cameraName || '';
    body.updatedAt = new Date().toISOString();
    // keep fields not present in the form (e.g. displayName set via rename API)
    const existing = config.cameraList[cameraName] || {};
    if (existing.displayName && !body.displayName) {
      body.displayName = existing.displayName;
    }
    config.cameraList[cameraName] = body;
    saveConfig(config);
  }
  res.send(renderIndex(cameraName, req.user.role, req.user));
});

const port = 64010; // Fixed port for OCR system
const host = process.env.HOST || '0.0.0.0'; // Bind to all interfaces
server.listen(port, host, async () => {
  console.info(`OCR HTTP Server listening on ${host}:${port} (FIXED PORT)`);
  console.info(`Access via: http://YOUR_IP:${port}`);
  ocrRunner(io);
  centralReporter.start();
});

const killWorkers = (exitCode) => {
  return (err) => {
    // console.log('EXIT Node', exitCode, err);
    process.exit();
  };
};

process.on('uncaughtException', killWorkers('uncaughtException'));
process.on('SIGINT', killWorkers('SIGINT'));
process.on('SIGTERM', killWorkers('SIGTERM'));
process.on('SIGTSTP', killWorkers('SIGTSTP'));
