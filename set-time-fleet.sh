#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Set the clock on many cameras at once, from this machine's time.
#
# A camera whose clock is behind stamps its reads with a past time. The center
# files those reads under old dates, so a report for this week comes out empty
# even though the camera is working perfectly. This fixes the cause.
#
# Usage
#   bash set-time-fleet.sh 10.11.181.43 10.11.181.45
#   bash set-time-fleet.sh -p raspberry -f cameras.txt
#   bash set-time-fleet.sh -p raspberry --from-db ~/Desktop/OCR-Center-main
#   bash set-time-fleet.sh --check --from-db ~/Desktop/OCR-Center-main   # look only
#
# Options
#   --check        show each camera's clock, change nothing
#   -f FILE        hosts from a file, one per line
#   --from-db DIR  hosts from the center's database
#   -u USER        ssh user                  (default: pi)
#   -p PASSWORD    ssh + sudo password, needs sshpass (ssh keys otherwise)
#
# Run it on a machine whose own clock is right - check with `date` first.
# ---------------------------------------------------------------------------
set -u

SSH_USER="pi"
SSH_PASS=""
CHECK_ONLY=0
HOSTS=()

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --check)   CHECK_ONLY=1; shift ;;
        -f)        [ $# -ge 2 ] || die "-f needs a file"
                   while IFS= read -r line; do
                       line="${line%%#*}"; line="$(echo "$line" | tr -d '[:space:]')"
                       [ -n "$line" ] && HOSTS+=("$line")
                   done < "$2"; shift 2 ;;
        --from-db) [ $# -ge 2 ] || die "--from-db needs the center folder"
                   [ -f "$2/data/center.db" ] || die "no data/center.db in $2"
                   while IFS= read -r line; do
                       [ -n "$line" ] && HOSTS+=("$line")
                   done < <(cd "$2" && node -e "
                     const db = require('better-sqlite3')('data/center.db');
                     for (const r of db.prepare('SELECT DISTINCT ip FROM devices WHERE ip IS NOT NULL').all()) {
                       console.log(r.ip);
                     }")
                   shift 2 ;;
        -u)        SSH_USER="$2"; shift 2 ;;
        -p)        SSH_PASS="$2"; shift 2 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        -*)        die "unknown option: $1" ;;
        *)         HOSTS+=("$1"); shift ;;
    esac
done

[ ${#HOSTS[@]} -gt 0 ] || die "no cameras given - see: bash set-time-fleet.sh --help"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"
SSH_CMD="ssh"
if [ -n "$SSH_PASS" ]; then
    command -v sshpass >/dev/null 2>&1 || die "-p needs sshpass (sudo apt install -y sshpass)"
    SSH_CMD="sshpass -p $SSH_PASS ssh"
fi

echo "เวลาเครื่องนี้ : $(date '+%Y-%m-%d %H:%M:%S')   (ตรวจให้แน่ใจว่าถูกต้องก่อน)"
echo "กล้อง         : ${#HOSTS[@]} ตัว"
echo ""

ok=0; fail=0; drifted=0
for host in "${HOSTS[@]}"; do
    NOW=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$CHECK_ONLY" = "1" ]; then
        REMOTE="date '+%Y-%m-%d %H:%M:%S'"
    else
        REMOTE="BEFORE=\$(date '+%Y-%m-%d %H:%M:%S');
                echo '$SSH_PASS' | sudo -S timedatectl set-ntp false >/dev/null 2>&1;
                echo '$SSH_PASS' | sudo -S timedatectl set-time '$NOW' >/dev/null 2>&1 ||
                echo '$SSH_PASS' | sudo -S date -s '$NOW' >/dev/null 2>&1;
                echo '$SSH_PASS' | sudo -S hwclock -w >/dev/null 2>&1;
                echo \"\$BEFORE -> \$(date '+%Y-%m-%d %H:%M:%S')\""
    fi

    RAW=$($SSH_CMD $SSH_OPTS "$SSH_USER@$host" "$REMOTE" 2>&1)
    STAMPS=$(echo "$RAW" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$')
    COUNT=$(printf '%s' "$STAMPS" | grep -c . || true)

    if [ "$COUNT" -ge 1 ]; then
        ok=$((ok + 1))
        BEFORE=$(echo "$STAMPS" | head -1)
        AFTER=$(echo "$STAMPS" | tail -1)
        # how far off the camera was, in minutes
        DIFF=$(( ( $(date -d "$NOW" +%s) - $(date -d "$BEFORE" +%s 2>/dev/null || date -d "$NOW" +%s) ) / 60 ))
        DIFF=${DIFF#-}
        if [ "$CHECK_ONLY" = "1" ]; then SHOWN="$BEFORE"; else SHOWN="$BEFORE  =>  $AFTER"; fi
        if [ "$DIFF" -gt 5 ]; then
            drifted=$((drifted + 1))
            printf '   %-16s %s   << เพี้ยน %s นาที\n' "$host" "$SHOWN" "$DIFF"
        else
            printf '   %-16s %s\n' "$host" "$SHOWN"
        fi
    else
        fail=$((fail + 1))
        printf '   %-16s ไม่สำเร็จ: %s\n' "$host" "$(echo "$RAW" | tail -1)"
    fi
done

echo ""
if [ "$CHECK_ONLY" = "1" ]; then
    echo "ตรวจแล้ว $ok ตัว (เพี้ยนเกิน 5 นาที $drifted ตัว), ติดต่อไม่ได้ $fail ตัว"
    [ "$drifted" -gt 0 ] && echo "สั่งแก้ด้วยคำสั่งเดิมแต่ตัด --check ออก"
else
    echo "ตั้งเวลาแล้ว $ok ตัว (แก้ที่เพี้ยนจริง $drifted ตัว), ติดต่อไม่ได้ $fail ตัว"
    echo "ข้อมูลเก่าที่บันทึกด้วยเวลาผิดยังอยู่ในวันเก่า ย้อนแก้ไม่ได้ - ข้อมูลใหม่จะตรงแล้ว"
fi
[ "$fail" -eq 0 ]
