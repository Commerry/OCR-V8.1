module.exports = {
  apps: [
    {
      name: 'ocr',
      script: './node_modules/.bin/babel-node',
      args: '-r dotenv/config ./src/server.js',
      interpreter: 'none',
      env: {
        NODE_ENV: 'production',
        BABEL_DISABLE_CACHE: '1'
      },
      error_file: './logs/err.log',
      out_file: './logs/out.log',
      log_date_format: 'YYYY-MM-DD HH:mm:ss',
      // the camera logs every frame - without a cap this filled 18GB on a device.
      // needs pm2-logrotate: pm2 install pm2-logrotate (update.sh does this)
      max_size: '20M',
      retain: 5,
      compress: true,
    },
  ],
};
