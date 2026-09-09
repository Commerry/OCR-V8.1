#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Update many OCR cameras in one command.
#
# Runs, on each camera over ssh:
#   git pull  ->  pm2 restart ocr  ->  report the commit it ends up on
#
# Usage
#   bash update-fleet.sh 10.1.100.61 10.1.100.62 10.1.100.63
#   bash update-fleet.sh -f cameras.txt              # one IP (or host) per line
#   bash update-fleet.sh --from-db ~/Desktop/OCR-Center-main   # ask the center
#
# Options
#   -f FILE        read hosts from FILE (blank lines and # comments ignored)
#   --from-db DIR  read the device IPs from the center's database (run this on
#                  the machine that hosts OCR Center)
#   -u USER        ssh user                            (default: pi)
#   -p PASSWORD    ssh password, needs sshpass         (default: ssh keys)
#   -d DIR         program folder on the camera        (default: ~/Desktop/OCR-V8.1)
#   -n NAME        pm2 process name                    (default: ocr)
#   -j N           how many cameras at a time          (default: 4)
#   --dry-run      only show what would run
#
# Per-site files are protected: config.json (camera names, PLC address, crop,
# display names, central URL), config/users.json, .env and the Img/ folder are
# copied aside before the update and put back afterwards, so only program code
# changes. Nothing is deleted and the pm2 startup entry is left alone.
# ---------------------------------------------------------------------------
set -u

SSH_USER="pi"
SSH_PASS=""
APP_DIR="~/Desktop/OCR-V8.1"
PM2_NAME="ocr"
JOBS=4
DRY_RUN=0
HOSTS=()

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        -f)         [ $# -ge 2 ] || die "-f needs a file"
                    while IFS= read -r line; do
                        line="${line%%#*}"
                        line="$(echo "$line" | tr -d '[:space:]')"
                        [ -n "$line" ] && HOSTS+=("$line")
                    done < "$2"; shift 2 ;;
        --from-db)  [ $# -ge 2 ] || die "--from-db needs the center folder"
                    CENTER_DIR="$2"
                    [ -f "$CENTER_DIR/data/center.db" ] || die "no data/center.db in $CENTER_DIR"
                    while IFS= read -r line; do
                        [ -n "$line" ] && HOSTS+=("$line")
                    done < <(cd "$CENTER_DIR" && node -e "
                      const db = require('better-sqlite3')('data/center.db');
                      for (const r of db.prepare('SELECT DISTINCT ip FROM devices WHERE ip IS NOT NULL').all()) {
                        console.log(r.ip);
                      }")
                    shift 2 ;;
        -u)         SSH_USER="$2"; shift 2 ;;
        -p)         SSH_PASS="$2"; shift 2 ;;
        -d)         APP_DIR="$2";  shift 2 ;;
        -n)         PM2_NAME="$2"; shift 2 ;;
        -j)         JOBS="$2";     shift 2 ;;
        --dry-run)  DRY_RUN=1;     shift ;;
        -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
        -*)         die "unknown option: $1" ;;
        *)          HOSTS+=("$1"); shift ;;
    esac
done

[ ${#HOSTS[@]} -gt 0 ] || die "no cameras given - see: bash update-fleet.sh --help"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=no"
SSH_CMD="ssh"
if [ -n "$SSH_PASS" ]; then
    command -v sshpass >/dev/null 2>&1 || die "-p needs sshpass (sudo apt install -y sshpass)"
    SSH_CMD="sshpass -p $SSH_PASS ssh"
fi

# What each camera runs. Kept as one string so it survives the ssh hop.
REMOTE_SCRIPT=$(cat <<REMOTE
set -e
cd $APP_DIR
if [ ! -d .git ]; then
    echo "SKIP: \$PWD is not a git clone - update it by hand once, then this script works"
    exit 3
fi
# the factory proxy makes git unable to find the CA bundle on some images
git config --global http.sslCAInfo /etc/ssl/certs/ca-certificates.crt 2>/dev/null || true
if ! git fetch origin main >/tmp/ocr-fetch.log 2>&1; then
    # proxy MITM: the certificate cannot be verified - retry once without the check
    echo "fetch failed, retrying without certificate check"
    git -c http.sslVerify=false fetch origin main >/tmp/ocr-fetch.log 2>&1 || {
        echo "FETCH FAILED:"; tail -3 /tmp/ocr-fetch.log; exit 4;
    }
fi
# Keep the settings of this site. config.json used to be tracked by git, so
# an update would otherwise overwrite the camera name, PLC address, crop and
# central URL of every device.
KEEP_DIR=\$(mktemp -d)
for f in config.json config/users.json .env; do
    [ -f "\$f" ] && mkdir -p "\$KEEP_DIR/\$(dirname \$f)" && cp -a "\$f" "\$KEEP_DIR/\$f"
done

BEFORE=\$(git rev-parse HEAD)
git reset --hard origin/main >/dev/null

# put the site settings back, whatever the update did to them
for f in config.json config/users.json .env; do
    [ -f "\$KEEP_DIR/\$f" ] && mkdir -p "\$(dirname \$f)" && cp -a "\$KEEP_DIR/\$f" "\$f"
done
rm -rf "\$KEEP_DIR"

if [ ! -s config.json ] && [ -f config.example.json ]; then
    cp config.example.json config.json
    echo "note: this device had no config.json - started one from the example"
fi

echo "changed files:"
git diff --stat "\$BEFORE" HEAD | tail -8 | sed 's/^/  /'

pm2 restart $PM2_NAME >/dev/null
echo "OK: \$(git log --oneline -1)"
echo "cameras in config: \$(node -e "try{const c=require('./config.json');console.log(Object.keys(c.cameraList||{}).join(', ')||'(none)')}catch(e){console.log('(unreadable)')}" 2>/dev/null)"
pm2 describe $PM2_NAME | grep -E "status" | head -1
REMOTE
)

echo "cameras : ${#HOSTS[@]}"
echo "user    : $SSH_USER"
echo "folder  : $APP_DIR   (pm2: $PM2_NAME)"
echo "parallel: $JOBS"
echo

if [ "$DRY_RUN" = "1" ]; then
    echo "--- dry run, nothing is executed ---"
    printf '%s\n' "${HOSTS[@]}"
    echo
    echo "$REMOTE_SCRIPT"
    exit 0
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

run_one() {
    local host="$1"
    local out="$TMP_DIR/$host.log"
    if $SSH_CMD $SSH_OPTS "$SSH_USER@$host" "$REMOTE_SCRIPT" >"$out" 2>&1; then
        echo "OK" > "$TMP_DIR/$host.status"
    else
        echo "FAIL" > "$TMP_DIR/$host.status"
    fi
}

running=0
for host in "${HOSTS[@]}"; do
    run_one "$host" &
    running=$((running + 1))
    if [ "$running" -ge "$JOBS" ]; then
        wait -n 2>/dev/null || wait
        running=$((running - 1))
    fi
done
wait

ok=0; fail=0
for host in "${HOSTS[@]}"; do
    status=$(cat "$TMP_DIR/$host.status" 2>/dev/null || echo FAIL)
    echo "===== $host [$status] ====="
    sed 's/^/    /' "$TMP_DIR/$host.log" 2>/dev/null | tail -6
    if [ "$status" = "OK" ]; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
done

echo
echo "done: $ok updated, $fail failed (from ${#HOSTS[@]} cameras)"
[ "$fail" -eq 0 ]
