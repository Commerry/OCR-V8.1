#!/bin/bash
# One-shot updater for cameras that ALREADY have an old program installed.
# Does NOT touch/delete old program folders (do that yourself).
#
# Order matters: clock -> proxy -> download (clone) -> install.
#   0. set the clock (wrong clock breaks TLS/apt)
#   1. set factory proxy (npm/pip/git/apt/env)
#   2. clone/update the program from GitHub
#   3. install Node if missing (tarball from the repo)
#   4. clear the OLD pm2 startup - whatever the old app name/path was
#   5. redis + npm dependencies (auto-downgrades npm 11 -> 10, known ARM bug)
#   6. python deps + .env
#   7. pm2 start + enable NEW startup on boot + verify
#
# Usage (run from anywhere, ALWAYS pass the current time):
#   bash update.sh "2026-08-06 21:30:00"                        <- site with direct internet
#   bash update.sh "2026-08-06 21:30:00" 10.201.0.54:8080       <- site behind a proxy
set -e

REPO="https://github.com/Commerry/OCR-V8.1.git"
APP_DIR="$HOME/Desktop/OCR-V8.1"

if [ -z "$1" ]; then
    echo "ERROR: ต้องใส่เวลาปัจจุบันทุกครั้ง (กันนาฬิกาเครื่องเพี้ยน)"
    echo "Usage: bash update.sh \"YYYY-MM-DD HH:MM:SS\" [PROXY_IP:PORT]"
    echo "เช่น:  bash update.sh \"2026-08-06 21:30:00\""
    echo "      bash update.sh \"2026-08-06 21:30:00\" 10.201.0.54:8080"
    exit 1
fi

echo "===== [0/7] Set clock ====="
sudo date -s "$1"
echo "clock = $(date)"

echo "===== [1/7] Proxy ====="
if [ -n "$2" ]; then
    PROXY="http://$2"
    npm config set proxy "$PROXY"
    npm config set https-proxy "$PROXY"
    npm config set strict-ssl false
    npm config set registry https://registry.npmjs.org/
    mkdir -p ~/.config/pip
    printf '[global]\nproxy = %s\n' "$PROXY" > ~/.config/pip/pip.conf
    git config --global http.proxy "$PROXY" 2>/dev/null || true
    git config --global https.proxy "$PROXY" 2>/dev/null || true
    echo "Acquire::http::Proxy \"$PROXY/\";
Acquire::https::Proxy \"$PROXY/\";" | sudo tee /etc/apt/apt.conf.d/95proxy > /dev/null
    sudo sed -i 's|http://|https://|g' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
    echo "export http_proxy=$PROXY
export https_proxy=$PROXY
export no_proxy=localhost,127.0.0.1,10.0.0.0/8" | sudo tee /etc/profile.d/proxy.sh > /dev/null
    export http_proxy="$PROXY" https_proxy="$PROXY" no_proxy=localhost,127.0.0.1,10.0.0.0/8
    echo "proxy = $PROXY"
else
    # no proxy given: clear any proxy left over from a previous run
    npm config delete proxy 2>/dev/null || true
    npm config delete https-proxy 2>/dev/null || true
    git config --global --unset http.proxy 2>/dev/null || true
    git config --global --unset https.proxy 2>/dev/null || true
    rm -f ~/.config/pip/pip.conf
    sudo rm -f /etc/apt/apt.conf.d/95proxy /etc/profile.d/proxy.sh
    unset http_proxy https_proxy
    echo "proxy = none (direct internet)"
fi

echo "-- connectivity check --"
if ! curl -sm 15 -o /dev/null -w "github: %{http_code}\n" https://raw.githubusercontent.com/ | grep -q "200\|301\|302"; then
    echo "ERROR: ต่อ github ไม่ได้ - ตรวจ proxy/เครือข่ายก่อน"
    echo "  ไซต์ที่ใช้ proxy: bash update.sh \"$1\" <PROXY_IP:PORT>"
    exit 1
fi

echo "===== [2/7] Download program from GitHub ====="
if [ -d "$APP_DIR/.git" ]; then
    cd "$APP_DIR"
    git fetch origin main
    git reset --hard origin/main
    echo "updated existing clone: $APP_DIR"
else
    mkdir -p "$(dirname "$APP_DIR")"
    rm -rf "$APP_DIR"
    git clone "$REPO" "$APP_DIR"
    cd "$APP_DIR"
    echo "cloned: $APP_DIR"
fi
git log --oneline -1

echo "===== [3/7] Node.js ====="
NODE_TARBALL="node-v24.14.0-linux-arm64.tar.xz"
if command -v node > /dev/null && [ "$(node -v | sed 's/^v//' | cut -d. -f1)" -ge 18 ]; then
    echo "node $(node -v) - ok"
elif [ -f "$NODE_TARBALL" ]; then
    echo "installing node from $NODE_TARBALL ..."
    sudo tar -xJf "$NODE_TARBALL" -C /usr/local --strip-components=1
    export PATH=/usr/local/bin:$PATH
    hash -r
    echo "node $(node -v) - installed"
else
    echo "ERROR: need node >= 18 and $NODE_TARBALL not found in this folder"
    exit 1
fi

echo "===== [4/7] Clear OLD pm2 startup ====="
if command -v pm2 > /dev/null; then
    pm2 delete all 2>/dev/null || true
    pm2 save --force 2>/dev/null || true
    sudo env PATH=$PATH "$(command -v pm2)" unstartup systemd -u "$USER" --hp "$HOME" 2>/dev/null || true
    pm2 kill 2>/dev/null || true
fi
sudo systemctl disable "pm2-$USER" 2>/dev/null || true
pkill -f main.py 2>/dev/null || true
echo "old pm2 startup cleared"

echo "===== [5/7] Redis + npm dependencies ====="
if ! command -v redis-server > /dev/null; then
    sudo apt-get update -o Acquire::http::No-Cache=true || true
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y redis-server
fi
sudo systemctl enable --now redis-server
redis-cli ping

echo "-- npm dependencies --"
# npm 11 has a fatal bug on ARM ("Exit handler never called") - use npm 10
if [ "$(npm -v | cut -d. -f1)" -ge 11 ]; then
    npm install -g npm@10.9.2 2>&1 | tail -1 || true
    hash -r
fi
echo "npm $(npm -v)"
rm -rf node_modules
npm install --no-audit --no-fund --legacy-peer-deps
chmod +x node_modules/.bin/*
npm run build || echo "warn: build failed (app runs from src - continuing)"

echo "===== [6/7] Python deps + .env ====="
python3 -m pip install --break-system-packages -r requirements.txt 2>/dev/null \
    || python3 -m pip install --user -r requirements.txt 2>/dev/null \
    || echo "warn: pip install failed (continuing)"
if [ ! -f ".env" ] && [ -f ".env.example" ]; then
    cp .env.example .env
    echo "created .env from .env.example"
fi
mkdir -p logs

echo "===== [7/7] pm2 start + NEW startup ====="
# cap pm2 logs - an unrotated out.log filled 18GB on a camera
pm2 install pm2-logrotate 2>&1 | tail -1 || true
pm2 set pm2-logrotate:max_size 20M 2>/dev/null || true
pm2 set pm2-logrotate:retain 5 2>/dev/null || true
pm2 set pm2-logrotate:compress true 2>/dev/null || true

pm2 start ecosystem.config.js
pm2 save --force
STARTUP_CMD=$(pm2 startup | grep "sudo env" | cut -d' ' -f2- || true)
if [ -n "$STARTUP_CMD" ]; then
    eval "sudo $STARTUP_CMD"
    pm2 save --force
    echo "startup enabled"
else
    echo "warn: run 'pm2 startup' manually, execute the sudo command it prints, then 'pm2 save'"
fi

echo "===== Verify ====="
sleep 8
pm2 status
HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:64010/login)
echo "web: $HTTP"
if [ "$HTTP" = "200" ]; then
    echo "=========================================="
    echo "UPDATE COMPLETE - ready to use"
    echo "  http://$(hostname -I | awk '{print $1}'):64010"
    echo "=========================================="
else
    echo "UPDATE FAILED - check: pm2 logs ocr --lines 30"
    exit 1
fi
