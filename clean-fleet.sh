#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Free disk space on many OCR cameras at once.
#
# Cleans the things that actually fill a CM4 - pm2 logs, the systemd journal,
# package caches and stale temp files - and reports how much each camera got
# back. Program files, config.json and saved images are never touched unless
# you ask for it with --images-days.
#
# Usage
#   bash clean-fleet.sh --report 10.1.100.61 10.1.100.62      # look first
#   bash clean-fleet.sh -p raspberry 10.1.100.61 10.1.100.62  # then clean
#   bash clean-fleet.sh -p raspberry -f cameras.txt
#   bash clean-fleet.sh -p raspberry --from-db ~/Desktop/OCR-Center-main
#
# Options
#   --report        show what is using the space, delete nothing
#   --dry-run       show what WOULD be deleted, delete nothing
#   --images-days N delete saved images older than N days (default: keep all)
#   --restart       restart pm2 afterwards, to release space held by deleted
#                   log files (a few seconds of downtime per camera)
#   -f FILE         hosts from a file, one per line
#   --from-db DIR   hosts from the center's database
#   -u USER         ssh user                        (default: pi)
#   -p PASSWORD     ssh + sudo password, needs sshpass
#   --sudo-pass P   sudo password only (use with ssh keys, no sshpass needed)
#   -d DIR          program folder on the camera    (default: ~/Desktop/OCR-V8.1)
#   -n NAME         pm2 process name                (default: ocr)
#   -j N            how many cameras at a time      (default: 4)
#
# Without -p, sudo steps (journal, apt cache) are skipped - everything that
# lives under the pi user is still cleaned.
# ---------------------------------------------------------------------------
set -u

SSH_USER="pi"
SSH_PASS=""
SUDO_PASS=""
APP_DIR="~/Desktop/OCR-V8.1"
PM2_NAME="ocr"
JOBS=4
MODE="clean"          # clean | dry | report
IMAGES_DAYS=""
DO_RESTART=0
HOSTS=()

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --report)      MODE="report"; shift ;;
        --dry-run)     MODE="dry"; shift ;;
        --images-days) IMAGES_DAYS="$2"; shift 2 ;;
        --restart)     DO_RESTART=1; shift ;;
        -f)            [ $# -ge 2 ] || die "-f needs a file"
                       while IFS= read -r line; do
                           line="${line%%#*}"
                           line="$(echo "$line" | tr -d '[:space:]')"
                           [ -n "$line" ] && HOSTS+=("$line")
                       done < "$2"; shift 2 ;;
        --from-db)     [ $# -ge 2 ] || die "--from-db needs the center folder"
                       [ -f "$2/data/center.db" ] || die "no data/center.db in $2"
                       while IFS= read -r line; do
                           [ -n "$line" ] && HOSTS+=("$line")
                       done < <(cd "$2" && node -e "
                         const db = require('better-sqlite3')('data/center.db');
                         for (const r of db.prepare('SELECT DISTINCT ip FROM devices WHERE ip IS NOT NULL').all()) {
                           console.log(r.ip);
                         }")
                       shift 2 ;;
        -u)            SSH_USER="$2"; shift 2 ;;
        -p)            SSH_PASS="$2"; shift 2 ;;
        --sudo-pass)   SUDO_PASS="$2"; shift 2 ;;
        -d)            APP_DIR="$2"; shift 2 ;;
        -n)            PM2_NAME="$2"; shift 2 ;;
        -j)            JOBS="$2"; shift 2 ;;
        -h|--help)     sed -n '2,36p' "$0"; exit 0 ;;
        -*)            die "unknown option: $1" ;;
        *)             HOSTS+=("$1"); shift ;;
    esac
done

[ ${#HOSTS[@]} -gt 0 ] || die "no cameras given - see: bash clean-fleet.sh --help"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
SSH_CMD="ssh"
if [ -n "$SSH_PASS" ]; then
    command -v sshpass >/dev/null 2>&1 || die "-p needs sshpass (sudo apt install -y sshpass), or use ssh keys plus --sudo-pass"
    SSH_CMD="sshpass -p $SSH_PASS ssh"
fi
# -p covers both by default; --sudo-pass is for key-based logins
[ -z "$SUDO_PASS" ] && SUDO_PASS="$SSH_PASS"

# The steps that run on each camera live in tools/clean-remote.sh, shared with
# the PowerShell version so both stay in step.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_FILE="$SCRIPT_DIR/tools/clean-remote.sh"
[ -f "$REMOTE_FILE" ] || die "ไม่พบ $REMOTE_FILE (git pull ใหม่อีกครั้ง)"
REMOTE_BODY=$(cat "$REMOTE_FILE")

echo "cameras : ${#HOSTS[@]}"
echo "user    : $SSH_USER   folder: $APP_DIR   pm2: $PM2_NAME"
echo "mode    : $MODE$([ -n "$IMAGES_DAYS" ] && echo "   images older than ${IMAGES_DAYS}d")$([ "$DO_RESTART" = 1 ] && echo '   +restart')"
echo

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

HOST_TIMEOUT="${HOST_TIMEOUT:-420}"

run_one() {
    local host="$1"
    local env_prefix="APP_DIR='$APP_DIR' PM2_NAME='$PM2_NAME' MODE='$MODE' IMAGES_DAYS='$IMAGES_DAYS' DO_RESTART='$DO_RESTART' SUDO_PASS='$SUDO_PASS'"
    # a camera that stops answering must not hold up the rest of the fleet
    local runner="$SSH_CMD"
    command -v timeout >/dev/null 2>&1 && runner="timeout $HOST_TIMEOUT $SSH_CMD"
    if echo "$REMOTE_BODY" | $runner $SSH_OPTS "$SSH_USER@$host" "$env_prefix bash -s" >"$TMP_DIR/$host.log" 2>&1; then
        echo OK > "$TMP_DIR/$host.status"
    else
        echo FAIL > "$TMP_DIR/$host.status"
    fi
    # print this camera as soon as it is done, skipping its login banner
    {
        flock 9
        echo "===== $host [$(cat "$TMP_DIR/$host.status")] ====="
        if grep -q '===OCR-CLEAN-BEGIN===' "$TMP_DIR/$host.log"; then
            sed -n '/===OCR-CLEAN-BEGIN===/,$p' "$TMP_DIR/$host.log" | sed '1d;s/^/  /'
        else
            sed 's/^/  /' "$TMP_DIR/$host.log"
        fi
        echo
    } 9>"$TMP_DIR/.print.lock"
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

# each camera already printed itself as it finished; just tally the result
ok=0; fail=0
for host in "${HOSTS[@]}"; do
    status=$(cat "$TMP_DIR/$host.status" 2>/dev/null || echo FAIL)
    if [ "$status" = OK ]; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
done

echo "done: $ok ok, $fail failed (from ${#HOSTS[@]} cameras)"
[ "$fail" -eq 0 ]
