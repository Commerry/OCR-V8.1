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
    },
  ],
};