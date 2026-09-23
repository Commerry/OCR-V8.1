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

# ---------------------------------------------------------------------------
# What runs on each camera. Sent over stdin, so nothing here needs escaping;
# settings arrive as environment variables.
# ---------------------------------------------------------------------------
REMOTE_BODY=$(cat <<'REMOTE'
set -u
cd "$APP_DIR" 2>/dev/null || true

human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }
free_kb() { df -Pk / | awk 'NR==2 {print $4}'; }
size_kb() { du -sk "$@" 2>/dev/null | awk '{s+=$1} END {print s+0}'; }

BEFORE=$(free_kb)
echo "ดิสก์: ใช้ไป $(df -Ph / | awk 'NR==2 {print $3" / "$2" ("$5")"}')  เหลือ $(df -Ph / | awk 'NR==2 {print $4}')"

echo "-- พื้นที่ที่ถูกใช้มากที่สุด --"
{
  [ -d "$APP_DIR/logs" ]  && echo "$(size_kb "$APP_DIR/logs") pm2 logs ในโปรแกรม ($APP_DIR/logs)"
  [ -d "$HOME/.pm2/logs" ] && echo "$(size_kb "$HOME/.pm2/logs") pm2 logs ส่วนกลาง (~/.pm2/logs)"
  [ -d "$APP_DIR/Img" ]   && echo "$(size_kb "$APP_DIR/Img") รูปที่กล้องเซฟไว้ ($APP_DIR/Img)"
  [ -d /var/log/journal ] && echo "$(size_kb /var/log/journal) systemd journal (/var/log/journal)"
  [ -d /var/cache/apt ]   && echo "$(size_kb /var/cache/apt) apt cache"
  [ -d "$HOME/.npm" ]     && echo "$(size_kb "$HOME/.npm") npm cache"
  [ -d "$HOME/.cache" ]   && echo "$(size_kb "$HOME/.cache") cache ของผู้ใช้ (~/.cache)"
  [ -f "$APP_DIR/python/log.txt" ] && echo "$(size_kb "$APP_DIR/python/log.txt") python/log.txt"
  echo "$(size_kb /tmp) /tmp"
} | sort -rn | head -8 | while read -r kb rest; do
  printf '   %8s  %s\n' "$(human $((kb * 1024)))" "$rest"
done

# files that are already deleted but still held open by a running process -
# this is the one that makes "I deleted the logs but nothing came back"
HELD=$(sudo -n lsof -nP +L1 2>/dev/null | awk '$0 !~ /^COMMAND/ {s+=$8} END {print s+0}')
[ "${HELD:-0}" -gt 10000000 ] 2>/dev/null && \
  echo "   $(human "$HELD")  ไฟล์ที่ลบแล้วแต่โปรเซสยังถือไว้ - ต้อง restart ถึงจะคืนพื้นที่ (ใช้ --restart)"

if [ "$MODE" = "report" ]; then
  echo "(โหมดดูอย่างเดียว ไม่มีการลบ)"
  exit 0
fi

DRY=0
[ "$MODE" = "dry" ] && DRY=1
say() { if [ "$DRY" = "1" ]; then echo "   [จะลบ] $*"; else echo "   [ลบ] $*"; fi; }
do_rm() { [ "$DRY" = "1" ] || eval "$@" >/dev/null 2>&1; }

echo "-- ทำความสะอาด --"

# 1. pm2 logs (the usual culprit: out.log grows without limit).
# An ssh command runs a non-login shell, so pm2 is often not on PATH here.
export PATH="$PATH:/usr/local/bin:/usr/bin:$HOME/.npm-global/bin"
for d in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$d" ] && PATH="$PATH:$d"; done

PM2_KB=$(( $(size_kb "$HOME/.pm2/logs") + $(size_kb "$APP_DIR/logs") ))
if [ "$PM2_KB" -gt 1024 ]; then
  say "pm2 logs $(human $((PM2_KB * 1024)))"
  command -v pm2 >/dev/null 2>&1 && do_rm "pm2 flush"
  # truncate rather than delete: a running process keeps writing to the same
  # file handle, so deleting it would not give the space back until a restart
  do_rm "find '$APP_DIR/logs' '$HOME/.pm2/logs' -name '*.log*' -exec truncate -s 0 {} +"
fi

if command -v pm2 >/dev/null 2>&1; then
  # keep it from happening again
  if ! pm2 list 2>/dev/null | grep -q pm2-logrotate; then
    say "ติดตั้ง pm2-logrotate (จำกัดขนาด log 20MB เก็บ 5 ไฟล์)"
    if [ "$DRY" != "1" ]; then
      pm2 install pm2-logrotate >/dev/null 2>&1 \
        && pm2 set pm2-logrotate:max_size 20M >/dev/null 2>&1 \
        && pm2 set pm2-logrotate:retain 5 >/dev/null 2>&1 \
        && pm2 set pm2-logrotate:compress true >/dev/null 2>&1
    fi
  fi
fi

# 2. the program's own python log
if [ -f "$APP_DIR/python/log.txt" ]; then
  KB=$(size_kb "$APP_DIR/python/log.txt")
  [ "$KB" -gt 1024 ] && { say "python/log.txt $(human $((KB * 1024)))"; do_rm "truncate -s 0 '$APP_DIR/python/log.txt'"; }
fi

# 3. caches that rebuild themselves
for dir in "$HOME/.npm/_cacache" "$HOME/.cache/pip" "$HOME/.cache/thumbnails"; do
  KB=$(size_kb "$dir")
  [ "$KB" -gt 1024 ] && { say "$dir $(human $((KB * 1024)))"; do_rm "rm -rf '$dir'"; }
done

# 4. stale temp files (leave anything touched in the last day alone)
KB=$(size_kb /tmp)
if [ "$KB" -gt 10240 ]; then
  say "ไฟล์ชั่วคราวเก่าใน /tmp $(human $((KB * 1024)))"
  # only files that are clearly leftovers - never the whole folder, which also
  # holds sockets and lock files that running programs need
  do_rm "find /tmp -maxdepth 1 -mtime +1 -type f \( -name 'ocr-*' -o -name 'tmp*' -o -name 'npm-*' -o -name '*.log' -o -name 'core.*' -o -name '*.jpg' -o -name '*.png' \) -delete"
fi

# 5. root-owned space - only with a password for sudo
if [ -n "${SUDO_PASS:-}" ]; then
  KB=$(size_kb /var/cache/apt/archives)
  if [ "$KB" -gt 1024 ]; then
    say "apt cache $(human $((KB * 1024)))"
    do_rm "echo '$SUDO_PASS' | sudo -S apt-get clean"
  fi
  KB=$(size_kb /var/log/journal)
  if [ "$KB" -gt 102400 ]; then
    say "systemd journal $(human $((KB * 1024))) -> เหลือ 100MB"
    do_rm "echo '$SUDO_PASS' | sudo -S journalctl --vacuum-size=100M"
  fi
  KB=$(size_kb /var/log)
  if [ "$KB" -gt 204800 ]; then
    say "log เก่าที่หมุนแล้วใน /var/log"
    do_rm "echo '$SUDO_PASS' | sudo -S find /var/log -type f \\( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \\) -delete"
  fi
else
  echo "   (ข้าม apt cache และ journal - ไม่ได้ใส่รหัส sudo: ใช้ -p หรือ --sudo-pass)"
fi

# 6. saved images, only when asked
if [ -n "${IMAGES_DAYS:-}" ] && [ -d "$APP_DIR/Img" ]; then
  N=$(find "$APP_DIR/Img" -type f -mtime +"$IMAGES_DAYS" 2>/dev/null | wc -l)
  if [ "$N" -gt 0 ]; then
    say "รูปเก่ากว่า $IMAGES_DAYS วัน จำนวน $N ไฟล์"
    do_rm "find '$APP_DIR/Img' -type f -mtime +$IMAGES_DAYS -delete"
  fi
fi

# 7. restart to hand back space still held by deleted files
if [ "$DO_RESTART" = "1" ] && [ "$DRY" != "1" ] && command -v pm2 >/dev/null 2>&1; then
  echo "   [restart] pm2 restart $PM2_NAME"
  pm2 restart "$PM2_NAME" >/dev/null 2>&1
  sleep 2
fi

AFTER=$(free_kb)
GAIN=$(( AFTER - BEFORE ))
[ "$GAIN" -lt 0 ] && GAIN=0
if [ "$DRY" = "1" ]; then
  echo "ผล: โหมดทดลอง ไม่ได้ลบจริง"
else
  echo "ผล: คืนพื้นที่ $(human $((GAIN * 1024)))  |  เหลือ $(df -Ph / | awk 'NR==2 {print $4" ("100-$5+0"% ว่าง)"}')"
fi
REMOTE
)

echo "cameras : ${#HOSTS[@]}"
echo "user    : $SSH_USER   folder: $APP_DIR   pm2: $PM2_NAME"
echo "mode    : $MODE$([ -n "$IMAGES_DAYS" ] && echo "   images older than ${IMAGES_DAYS}d")$([ "$DO_RESTART" = 1 ] && echo '   +restart')"
echo

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

run_one() {
    local host="$1"
    local env_prefix="APP_DIR='$APP_DIR' PM2_NAME='$PM2_NAME' MODE='$MODE' IMAGES_DAYS='$IMAGES_DAYS' DO_RESTART='$DO_RESTART' SUDO_PASS='$SUDO_PASS'"
    if echo "$REMOTE_BODY" | $SSH_CMD $SSH_OPTS "$SSH_USER@$host" "$env_prefix bash -s" >"$TMP_DIR/$host.log" 2>&1; then
        echo OK > "$TMP_DIR/$host.status"
    else
        echo FAIL > "$TMP_DIR/$host.status"
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
    sed 's/^/  /' "$TMP_DIR/$host.log" 2>/dev/null
    echo
    if [ "$status" = OK ]; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
done

echo "done: $ok ok, $fail failed (from ${#HOSTS[@]} cameras)"
[ "$fail" -eq 0 ]
