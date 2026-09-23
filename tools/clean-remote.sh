#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Runs ON a camera. Sent over ssh stdin by clean-fleet.sh / clean-fleet.ps1.
#
# Settings arrive as environment variables:
#   APP_DIR PM2_NAME MODE(report|dry|clean) IMAGES_DAYS DO_RESTART SUDO_PASS
#
# Frees the things that actually fill a CM4 and shows what is left, so a
# camera that is still full afterwards tells you why instead of staying a
# mystery. Program files, config.json, saved images and the database are never
# touched (images only when IMAGES_DAYS says so).
# ---------------------------------------------------------------------------
set -u

APP_DIR="${APP_DIR:-$HOME/Desktop/OCR-V8.1}"
PM2_NAME="${PM2_NAME:-ocr}"
MODE="${MODE:-report}"
IMAGES_DAYS="${IMAGES_DAYS:-0}"
DO_RESTART="${DO_RESTART:-0}"
SUDO_PASS="${SUDO_PASS:-}"

cd "$APP_DIR" 2>/dev/null || true
export PATH="$PATH:/usr/local/bin:/usr/bin:$HOME/.npm-global/bin"
for d in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$d" ] && PATH="$PATH:$d"; done

human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }
free_kb() { df -Pk / | awk 'NR==2 {print $4}'; }
size_kb() { du -sk "$@" 2>/dev/null | awk '{s+=$1} END {print s+0}'; }
SUDO() { if [ -n "$SUDO_PASS" ]; then echo "$SUDO_PASS" | sudo -S "$@" 2>/dev/null; else sudo -n "$@" 2>/dev/null; fi; }
# Scanning a whole SD card takes minutes on slow storage. Every survey step
# runs under a time limit so a slow camera reports what it managed to find
# instead of holding up the whole fleet.
if command -v timeout >/dev/null 2>&1; then
  TMO() { local t="$1"; shift; timeout "$t" "$@"; }
else
  TMO() { shift; "$@"; }
fi
SUDO_TMO() { # SUDO_TMO <seconds> <command...>
  local t="$1"; shift
  if [ -n "$SUDO_PASS" ]; then echo "$SUDO_PASS" | TMO "$t" sudo -S "$@" 2>/dev/null
  else TMO "$t" sudo -n "$@" 2>/dev/null; fi
}

echo "===OCR-CLEAN-BEGIN==="
BEFORE=$(free_kb)
echo "ดิสก์: $(df -Ph / | awk 'NR==2 {print "ใช้ "$3" / "$2" ("$5")  เหลือ "$4}')"

# --------------------------------------------------------------- survey ----
# Real answer to "what is filling this card": every directory on the root
# filesystem, not just the ones this script knows about.
echo "-- โฟลเดอร์ที่ใหญ่ที่สุดในเครื่อง --"
# with sudo it sees the whole card; without, the home folder, logs and /tmp
# still cover everything this program can be blamed for
DIRS=$(SUDO_TMO 75 du -x -d 2 --exclude=/proc --exclude=/sys / | sort -rn | awk '$1 > 51200' | head -12)
[ -z "$DIRS" ] && DIRS=$(TMO 60 du -x -d 2 "$HOME" /var/log /var/cache /tmp 2>/dev/null | sort -rn | awk '$1 > 51200' | head -12)
if [ -n "$DIRS" ]; then
  echo "$DIRS" | while read -r kb path; do printf '   %9s  %s\n' "$(human $((kb * 1024)))" "$path"; done
else
  echo "   (สแกนไม่ทันในเวลาที่กำหนด)"
fi

# The whole-card file hunt is the slowest step of all: worth it when you are
# looking for what to do, pointless when the job is to clean.
if [ "$MODE" = "report" ]; then
  echo "-- ไฟล์เดี่ยวที่ใหญ่กว่า 100MB --"
  BIG=$(SUDO_TMO 90 find / -xdev -type f -size +100M -printf '%s %p\n' | sort -rn | head -10)
  [ -z "$BIG" ] && BIG=$(TMO 60 find "$HOME" /var/log /tmp -xdev -type f -size +100M -printf '%s %p\n' 2>/dev/null | sort -rn | head -10)
  if [ -n "$BIG" ]; then
    echo "$BIG" | while read -r b path; do printf '   %9s  %s\n' "$(human "$b")" "$path"; done
  else
    echo "   (ไม่มี)"
  fi
fi

# Space that df counts but ls cannot show you: files deleted while a process
# still had them open. This is what makes "I cleaned it and nothing changed".
HELD=$(SUDO_TMO 30 lsof -nP +L1 | awk '$0 !~ /^COMMAND/ && $8 ~ /^[0-9]+$/ {s+=$8} END {print s+0}')
if [ "${HELD:-0}" -gt 10000000 ] 2>/dev/null; then
  echo "-- ไฟล์ที่ลบแล้วแต่โปรเซสยังถือไว้ $(human "$HELD") --"
  SUDO_TMO 30 lsof -nP +L1 | awk '$8 ~ /^[0-9]+$/ && $8 > 10000000 {printf "   %s (pid %s) %s\n", $1, $2, $9}' | head -6
fi

if [ "$MODE" = "report" ]; then
  echo "(โหมดดูอย่างเดียว ไม่มีการลบ)"
  exit 0
fi

DRY=0
[ "$MODE" = "dry" ] && DRY=1
say()   { if [ "$DRY" = "1" ]; then echo "   [จะลบ] $*"; else echo "   [ลบ] $*"; fi; }
do_rm() { [ "$DRY" = "1" ] || eval "$@" >/dev/null 2>&1; }
# only mention a target when it is actually worth cleaning
maybe() { # maybe <min_kb> <label> <command...>
  local min="$1"; shift
  local label="$1"; shift
  local path_kb="$1"; shift
  [ "$path_kb" -lt "$min" ] && return 0
  say "$label $(human $((path_kb * 1024)))"
  do_rm "$@"
}

echo "-- ทำความสะอาด --"

# 1. pm2 logs, and the handles the daemon still holds
PM2_KB=$(( $(size_kb "$HOME/.pm2/logs") + $(size_kb "$APP_DIR/logs") ))
maybe 1024 "pm2 logs" "$PM2_KB" \
  "command -v pm2 >/dev/null 2>&1 && pm2 flush; find '$APP_DIR/logs' '$HOME/.pm2/logs' -name '*.log*' -exec truncate -s 0 {} +"
command -v pm2 >/dev/null 2>&1 && do_rm "pm2 reloadLogs"

if command -v pm2 >/dev/null 2>&1 && ! pm2 list 2>/dev/null | grep -q pm2-logrotate; then
  say "ติดตั้ง pm2-logrotate (20MB x 5 ไฟล์)"
  if [ "$DRY" != "1" ]; then
    pm2 install pm2-logrotate >/dev/null 2>&1 \
      && pm2 set pm2-logrotate:max_size 20M >/dev/null 2>&1 \
      && pm2 set pm2-logrotate:retain 5 >/dev/null 2>&1 \
      && pm2 set pm2-logrotate:compress true >/dev/null 2>&1
  fi
fi

# 2. logs of the program itself, including copies left by older installs
maybe 1024 "python/log.txt" "$(size_kb "$APP_DIR/python/log.txt")" \
  "truncate -s 0 '$APP_DIR/python/log.txt'"

for old in "$HOME"/Desktop/OCR*/logs "$HOME"/OCR*/logs "$HOME"/Desktop/OCR*/python/log.txt; do
  [ -e "$old" ] || continue
  case "$old" in "$APP_DIR"/*) continue ;; esac
  maybe 10240 "log ของโปรแกรมชุดเก่า ($old)" "$(size_kb "$old")" \
    "find '$old' -type f -exec truncate -s 0 {} + 2>/dev/null || truncate -s 0 '$old'"
done

# 3. caches - all of them rebuild themselves
maybe 1024 "~/.cache ทั้งหมด" "$(size_kb "$HOME/.cache")" "rm -rf '$HOME/.cache'/*"
maybe 1024 "npm cache" "$(size_kb "$HOME/.npm/_cacache")" "rm -rf '$HOME/.npm/_cacache'"
maybe 1024 "ถังขยะของเดสก์ท็อป" "$(size_kb "$HOME/.local/share/Trash")" "rm -rf '$HOME/.local/share/Trash'/*"
maybe 1024 "thumbnails" "$(size_kb "$HOME/.thumbnails")" "rm -rf '$HOME/.thumbnails'/*"
maybe 512  "__pycache__ ของโปรแกรม" "$(size_kb "$APP_DIR/python/__pycache__")" \
  "find '$APP_DIR' -name '__pycache__' -type d -prune -exec rm -rf {} +"

# 4. temporary files
maybe 10240 "ไฟล์ชั่วคราวเก่าใน /tmp" "$(size_kb /tmp)" \
  "find /tmp -maxdepth 1 -mtime +1 -type f \( -name 'ocr-*' -o -name 'tmp*' -o -name 'npm-*' -o -name '*.log' -o -name 'core.*' -o -name '*.jpg' -o -name '*.png' -o -name '*.webp' \) -delete"
maybe 10240 "/var/tmp" "$(size_kb /var/tmp)" "find /var/tmp -mindepth 1 -mtime +3 -delete"

# 5. root-owned junk (needs the sudo password)
if [ -n "$SUDO_PASS" ] || sudo -n true 2>/dev/null; then
  KB=$(size_kb /var/cache/apt/archives); if [ "$KB" -gt 1024 ]; then
    say "แพ็กเกจ .deb ที่ดาวน์โหลดค้างไว้ $(human $((KB * 1024)))"
    do_rm "SUDO_TMO 60 apt-get clean"
  fi
  KB=$(size_kb /var/lib/apt/lists); if [ "$KB" -gt 20480 ]; then
    say "รายการแพ็กเกจ apt $(human $((KB * 1024))) (สร้างใหม่เองตอน apt update)"
    do_rm "SUDO rm -rf /var/lib/apt/lists"
  fi
  KB=$(size_kb /var/log/journal); if [ "$KB" -gt 51200 ]; then
    say "systemd journal $(human $((KB * 1024))) -> เหลือ 50MB"
    do_rm "SUDO_TMO 90 journalctl --vacuum-size=50M"
  fi
  KB=$(size_kb /var/log); if [ "$KB" -gt 51200 ]; then
    say "log เก่าที่หมุนแล้วใน /var/log"
    do_rm "SUDO find /var/log -type f \( -name '*.gz' -o -name '*.xz' -o -name '*.old' -o -name '*.[0-9]' -o -name '*.[0-9].*' \) -delete"
    say "ตัด log ที่ยังใช้งานอยู่ให้ว่าง (syslog, kern.log, daemon.log ...)"
    do_rm "SUDO find /var/log -maxdepth 1 -type f -size +20M -exec truncate -s 0 {} +"
  fi
  KB=$(size_kb /var/crash); [ "$KB" -gt 1024 ] && { say "รายงาน crash เก่า $(human $((KB * 1024)))"; do_rm "SUDO rm -rf /var/crash/*"; }
  KB=$(size_kb /var/lib/systemd/coredump); [ "$KB" -gt 1024 ] && { say "core dump $(human $((KB * 1024)))"; do_rm "SUDO rm -rf /var/lib/systemd/coredump/*"; }
  KB=$(size_kb /root/.cache); [ "$KB" -gt 1024 ] && { say "cache ของ root $(human $((KB * 1024)))"; do_rm "SUDO rm -rf /root/.cache/* /root/.npm/_cacache"; }
  # packages left behind by upgrades
  if command -v apt-get >/dev/null 2>&1; then
    AUTO=$(SUDO_TMO 40 apt-get -s autoremove | grep -c '^Remv')
    if [ "${AUTO:-0}" -gt 0 ]; then
      say "แพ็กเกจที่ไม่มีอะไรใช้แล้ว $AUTO รายการ"
      do_rm "SUDO_TMO 180 apt-get -y autoremove --purge"
    fi
  fi
else
  echo "   (ข้ามส่วนที่ต้องใช้ sudo - ไม่ได้ส่งรหัสมา)"
fi

# 6. saved images, only when asked
if [ "${IMAGES_DAYS:-0}" -gt 0 ]; then
  for imgdir in "$APP_DIR/Img" "$HOME"/Desktop/OCR*/Img; do
    [ -d "$imgdir" ] || continue
    N=$(find "$imgdir" -type f -mtime +"$IMAGES_DAYS" 2>/dev/null | wc -l)
    [ "$N" -gt 0 ] || continue
    say "รูปเก่ากว่า $IMAGES_DAYS วันใน $imgdir จำนวน $N ไฟล์"
    do_rm "find '$imgdir' -type f -mtime +$IMAGES_DAYS -delete"
  done
fi

# 7. hand back space still held by deleted files
if [ "$DRY" != "1" ]; then
  STILL=$(SUDO_TMO 30 lsof -nP +L1 | awk '$0 !~ /^COMMAND/ && $8 ~ /^[0-9]+$/ {s+=$8} END {print s+0}')
  if [ "${STILL:-0}" -gt 100000000 ] 2>/dev/null && [ "$DO_RESTART" != "1" ]; then
    echo "   เหลือ $(human "$STILL") ที่ยังถูกโปรเซสถือไว้ - สั่งซ้ำพร้อม --restart / -Restart เพื่อคืนส่วนนี้"
    SUDO_TMO 30 lsof -nP +L1 | awk '$8 ~ /^[0-9]+$/ && $8 > 50000000 {printf "      %s (pid %s) %s\n", $1, $2, $9}' | head -4
  fi
fi

if [ "$DO_RESTART" = "1" ] && [ "$DRY" != "1" ]; then
  if command -v pm2 >/dev/null 2>&1; then
    echo "   [restart] pm2 update"
    pm2 update >/dev/null 2>&1 || pm2 restart "$PM2_NAME" >/dev/null 2>&1
  fi
  # services that commonly sit on deleted log files
  for svc in rsyslog systemd-journald; do
    SUDO systemctl is-active --quiet "$svc" 2>/dev/null && do_rm "SUDO systemctl restart $svc"
  done
  sleep 3
fi

AFTER=$(free_kb)
GAIN=$(( AFTER - BEFORE ))
[ "$GAIN" -lt 0 ] && GAIN=0
if [ "$DRY" = "1" ]; then
  echo "ผล: โหมดทดลอง ไม่ได้ลบจริง"
else
  echo "ผล: คืนพื้นที่ $(human $((GAIN * 1024)))  |  $(df -Ph / | awk 'NR==2 {print "เหลือ "$4" (ใช้ไป "$5")"}')"
fi
