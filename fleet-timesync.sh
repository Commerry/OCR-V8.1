#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Same job as fleet-timesync.ps1, for running from the center (Linux).
#
# Updates ONLY the three files the clock sync needs, so each site keeps its own
# config.json and its own edits to the web page:
#
#     src/utils/timeSync.js               (new)
#     src/utils/centralReporter.js        (changed)
#     tools/install-timesync-sudoers.sh   (new)
#
# Usage
#   bash fleet-timesync.sh --status                 # look, change nothing
#   bash fleet-timesync.sh --setup-keys             # install an ssh key once
#   bash fleet-timesync.sh --apply
#   bash fleet-timesync.sh --verify
#   bash fleet-timesync.sh --apply 10.15.161.21 10.41.182.16
#
# Options
#   -u USER       ssh user                    (default: pi)
#   -p PASSWORD   ssh + sudo password         (default: raspberry)
#   -d DIR        program folder on a camera  (found via pm2 when missing)
#   -n NAME       pm2 process name            (default: ocr)
#   -f FILE       read hosts from a file
#   --with-deps   also carry systemHealth.js and ocrRunner.js to a camera
#                 whose program is old enough to be missing them
# ---------------------------------------------------------------------------
set -u

SSH_USER="pi"
PASSWORD="raspberry"
APP_DIR='$HOME/Desktop/OCR-V8.1'
PM2_NAME="ocr"
MODE="status"
WITH_DEPS=0
HOSTS=()

FILES="src/utils/timeSync.js src/utils/centralReporter.js tools/install-timesync-sudoers.sh"
KEY="$HOME/.ssh/ocr_fleet_ed25519"

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --status)     MODE="status"; shift ;;
        --apply)      MODE="apply"; shift ;;
        --verify)     MODE="verify"; shift ;;
        --setup-keys) MODE="keys"; shift ;;
        --with-deps)  WITH_DEPS=1; shift ;;
        -u) SSH_USER="$2"; shift 2 ;;
        -p) PASSWORD="$2"; shift 2 ;;
        -d) APP_DIR="$2"; shift 2 ;;
        -n) PM2_NAME="$2"; shift 2 ;;
        -f) while IFS= read -r line; do
                line="${line%%#*}"; line="$(echo "$line" | tr -d '[:space:]')"
                [ -n "$line" ] && HOSTS+=("$line")
            done < "$2"; shift 2 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *)  HOSTS+=("$1"); shift ;;
    esac
done

if [ ${#HOSTS[@]} -eq 0 ]; then
    HOSTS=(
        10.41.182.15 10.41.182.17
        10.31.182.15 10.31.182.16 10.31.182.17
        10.31.181.27 10.31.181.28
        10.32.181.15 10.32.181.16
        10.36.181.35 10.36.181.36 10.36.181.37
        10.11.181.43 10.11.181.45 10.11.181.47 10.11.181.49
        10.15.161.21 10.15.161.22
    )
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o LogLevel=ERROR"
KEY_OPTS=""
[ -f "$KEY" ] && KEY_OPTS="-i $KEY"

# ---------------------------------------------------------------------------
# Feeding the password: no sshpass on these machines, but OpenSSH 8.4+ takes
# SSH_ASKPASS_REQUIRE=force, which makes it ask a program instead of the
# terminal. setsid detaches from the tty so the prompt cannot come back to us.
# ---------------------------------------------------------------------------
ASKPASS=$(mktemp)
printf '#!/bin/sh\necho %s\n' "$PASSWORD" > "$ASKPASS"
chmod 700 "$ASKPASS"
trap 'rm -f "$ASKPASS"' EXIT

ssh_pw() { # ssh using the password, for the first contact with a camera
    if command -v setsid >/dev/null 2>&1; then
        SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
            setsid -w ssh $SSH_OPTS -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
            "$SSH_USER@$1" "$2" 2>&1
    else
        # no setsid (git-bash on Windows): let ssh ask on screen instead
        ssh $SSH_OPTS -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
            "$SSH_USER@$1" "$2" 2>&1
    fi
}

ssh_key() { # ssh using the key, for everything afterwards
    ssh $SSH_OPTS $KEY_OPTS -o BatchMode=yes "$SSH_USER@$1" "$2" 2>&1
}

remote_prelude() {
    cat <<PRELUDE
export PATH="\$PATH:/usr/local/bin:/usr/bin:/usr/local/lib/npm/bin:\$HOME/.npm-global/bin:\$HOME/.local/bin:\$HOME/bin"
for d in "\$HOME"/.nvm/versions/node/*/bin /opt/node*/bin /usr/local/n/versions/node/*/bin; do
    [ -d "\$d" ] && PATH="\$PATH:\$d"
done
# pm2 turns up in different places depending on how node was installed on each
# camera; find the binary rather than trusting PATH alone
PM2=\$(command -v pm2 2>/dev/null)
if [ -z "\$PM2" ]; then
    for c in /usr/local/bin/pm2 /usr/bin/pm2 \$HOME/.npm-global/bin/pm2              \$HOME/.nvm/versions/node/*/bin/pm2 /opt/node*/bin/pm2              \$HOME/node_modules/.bin/pm2 ./node_modules/.bin/pm2; do
        [ -x "\$c" ] && { PM2="\$c"; break; }
    done
fi
[ -n "\$PM2" ] || PM2=pm2
pm2() { "\$PM2" "\$@"; }
echo PM2BIN \$PM2
DIR=$APP_DIR
[ -d "\$DIR" ] || DIR=\$(pm2 describe $PM2_NAME 2>/dev/null | grep -m1 'exec cwd' | sed 's/.*│ *//;s/ *│.*//')
[ -d "\$DIR" ] || DIR=\$(ls -d \$HOME/Desktop/OCR* \$HOME/OCR* 2>/dev/null | head -1)
[ -d "\$DIR" ] || { echo ERRDIR; exit 1; }
cd "\$DIR" || { echo ERRDIR; exit 1; }
# The pm2 app is not called the same thing on every camera. Ask pm2 which app
# runs from this folder rather than assuming a name - guessing it made four
# cameras look dead and get rolled back while they were running fine.
APP=$PM2_NAME
if ! pm2 describe "\$APP" >/dev/null 2>&1; then
    APP=\$(DIR="\$DIR" pm2 jlist 2>/dev/null | node -e '
        let s = "";
        process.stdin.on("data", (d) => { s += d; }).on("end", () => {
          try {
            const apps = JSON.parse(s);
            const here = apps.find((a) => a.pm2_env && a.pm2_env.pm_cwd
              && a.pm2_env.pm_cwd.indexOf(process.env.DIR) === 0);
            const pick = here || apps[0];
            if (pick) console.log(pick.name);
          } catch (e) { /* no pm2 or bad json */ }
        });' 2>/dev/null)
fi
[ -n "\$APP" ] || APP=$PM2_NAME
echo APP \$APP
PRELUDE
}

# ---- one-time: put our key on every camera ----
if [ "$MODE" = "keys" ]; then
    [ -f "$KEY" ] || ssh-keygen -t ed25519 -N '' -f "$KEY" -C "ocr-fleet-$(hostname)" >/dev/null
    PUB=$(cut -d' ' -f1-2 "$KEY.pub")
    echo "ติดตั้ง key บน ${#HOSTS[@]} ตัว"
    for h in "${HOSTS[@]}"; do
        out=$(ssh_pw "$h" "mkdir -p ~/.ssh; chmod 700 ~/.ssh; echo '$PUB ocr-fleet' >> ~/.ssh/authorized_keys; sort -u -o ~/.ssh/authorized_keys ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys; echo KEY_OK")
        if echo "$out" | grep -q KEY_OK; then printf '   %-16s ติดตั้งแล้ว\n' "$h"
        else printf '   %-16s ไม่สำเร็จ: %s\n' "$h" "$(echo "$out" | tail -1)"; fi
    done
    exit 0
fi

echo "=== fleet-timesync ($MODE) - กล้อง ${#HOSTS[@]} ตัว ==="
[ -f "$KEY" ] || echo "(ยังไม่มี ssh key - จะใช้รหัสผ่านแทน หรือสั่ง --setup-keys ครั้งเดียวให้เร็วขึ้น)"
echo

ok=0; bad=0
for h in "${HOSTS[@]}"; do
    case "$MODE" in
    status)
        script="$(remote_prelude)
echo DIR \$DIR
echo COMMIT \$(git log --oneline -1 2>/dev/null | cut -c1-50)
echo TIME \$(date '+%Y-%m-%d %H:%M:%S %Z')
echo TIMESYNC \$([ -f src/utils/timeSync.js ] && echo yes || echo no)
echo SUDOERS \$([ -f /etc/sudoers.d/ocr-settime ] && echo yes || echo no)
echo HASHEALTH \$([ -f src/utils/systemHealth.js ] && echo yes || echo no)
echo HASRUNNER \$(grep -c getRecentReads src/ocrRunner.js 2>/dev/null || echo 0)
echo TARGETDIRTY \$(git status --porcelain -- $FILES 2>/dev/null | grep -v '^??' | wc -l)"
        ;;
    apply)
        # Step one only fetches the files. Cameras that cannot reach GitHub -
        # no git repo, or a proxy that breaks the fetch - get the same files
        # copied straight from this machine instead, so every camera can be
        # updated regardless of its network.
        script="$(remote_prelude)
echo DIR \$DIR
if [ "$WITH_DEPS" != "1" ]; then
    [ -f src/utils/systemHealth.js ] || { echo ERRDEPS; exit 1; }
    grep -q getRecentReads src/ocrRunner.js 2>/dev/null || { echo ERRDEPS; exit 1; }
fi
cp -a src/utils/centralReporter.js /tmp/centralReporter.bak.js 2>/dev/null
if [ -d .git ]; then
    git config --global http.sslCAInfo /etc/ssl/certs/ca-certificates.crt 2>/dev/null || true
    if git fetch origin main >/tmp/ts.log 2>&1 || git -c http.sslVerify=false fetch origin main >/tmp/ts.log 2>&1; then
        git checkout origin/main -- $FILES && echo GOTFILES git
    fi
fi
[ -f src/utils/timeSync.js ] || echo NEEDFILES yes"
        ;;
    verify)
        script="$(remote_prelude)
echo TIMESYNC \$([ -f src/utils/timeSync.js ] && echo yes || echo no)
echo SUDOOK \$(sudo -n timedatectl show -p Timezone --value >/dev/null 2>&1 && echo yes || echo no)
echo EPOCH \$(date +%s)
echo TZ \$(date '+%z')
echo PM2 \$(pm2 describe "\$APP" 2>/dev/null | grep -m1 status | grep -o 'online\\|errored\\|stopped')
echo SYNCED \$(grep -h -c timeSync logs/*.log \$HOME/.pm2/logs/*out*.log 2>/dev/null | paste -sd+ | bc 2>/dev/null || echo 0)"
        ;;
    esac

    if [ -f "$KEY" ]; then out=$(ssh_key "$h" "$script"); else out=$(ssh_pw "$h" "$script"); fi
    get() { echo "$out" | grep -m1 "^$1 " | cut -d' ' -f2-; }

    # Cameras that cannot reach GitHub - no git repo, or a proxy that breaks
    # the fetch - get the same files copied straight from this machine, so the
    # network a camera happens to have does not decide whether it can be fixed.
    if [ "$MODE" = apply ] && ! echo "$out" | grep -qE 'ERRDIR|ERRDEPS'; then
        remote_dir=$(get DIR)
        if [ -n "$remote_dir" ] && ! echo "$out" | grep -q '^GOTFILES '; then
            copied=yes
            send="$FILES"
            [ "$WITH_DEPS" = 1 ] && send="$send src/utils/systemHealth.js src/ocrRunner.js"
            for f in $send; do
                ssh_key "$h" "mkdir -p \$(dirname '$remote_dir/$f')" >/dev/null 2>&1
                scp $SSH_OPTS $KEY_OPTS -q "$f" "$SSH_USER@$h:$remote_dir/$f" 2>/dev/null || copied=no
            done
            if [ "$copied" = yes ]; then out="$out
GOTFILES copy"; else out="$out
ERRCOPY yes"; fi
        fi

        if echo "$out" | grep -q '^GOTFILES '; then
            finish="$(remote_prelude)
echo '$PASSWORD' | sudo -S bash tools/install-timesync-sudoers.sh $SSH_USER >/tmp/ts-sudo.log 2>&1
echo SUDOERS \$([ -f /etc/sudoers.d/ocr-settime ] && echo yes || echo no)
pm2 restart "\$APP" >/dev/null 2>&1
STATUS=
for i in 1 2 3 4 5 6 7 8; do
    sleep 2
    STATUS=\$(pm2 describe "\$APP" 2>/dev/null | grep -m1 'status' | grep -o 'online\\|errored\\|stopped\\|launching')
    [ \"\$STATUS\" = online ] && break
done
echo PM2 \$STATUS
if [ \"\$STATUS\" != online ]; then
    echo WHY \$(pm2 logs "\$APP" --err --lines 8 --nostream 2>/dev/null | tail -3 | tr '\\n' ' ' | cut -c1-200)
    cp -a /tmp/centralReporter.bak.js src/utils/centralReporter.js 2>/dev/null
    rm -f src/utils/timeSync.js
    pm2 restart "\$APP" >/dev/null 2>&1
    echo ROLLEDBACK yes
fi
echo TIME \$(date '+%Y-%m-%d %H:%M:%S %Z')"
            if [ -f "$KEY" ]; then more=$(ssh_key "$h" "$finish"); else more=$(ssh_pw "$h" "$finish"); fi
            out="$out
$more"
        fi
    fi

    # A camera that answers nothing at all is a failure, not a pass - the
    # PowerShell version reported unreachable hosts as healthy until it
    # required a known line in the reply.
    case "$MODE" in
        status) marker=DIR ;;
        apply)  marker=TIME ;;
        verify) marker=EPOCH ;;
    esac
    if echo "$out" | grep -qE 'ERRDIR|ERRDEPS|ERRCOPY' \
       || ! echo "$out" | grep -q "^$marker "; then
        reason=$(echo "$out" | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-70)
        printf '%-16s ปัญหา: %s\n' "$h" "${reason:-ไม่มีคำตอบจากเครื่อง}"
        bad=$((bad + 1))
        continue
    fi

    case "$MODE" in
    status)
        printf '%-16s %s\n' "$h" "$(get COMMIT)"
        printf '                 เวลา %s | timeSync %s | สิทธิ์ %s | systemHealth %s | ไฟล์ที่จะทับถูกแก้ไว้ %s\n' \
            "$(get TIME)" "$(get TIMESYNC)" "$(get SUDOERS)" "$(get HASHEALTH)" "$(get TARGETDIRTY)"
        ok=$((ok + 1))
        ;;
    apply)
        if [ "$(get ROLLEDBACK)" = yes ]; then
            printf '%-16s โปรแกรมไม่ขึ้น (pm2 %s) - คืนไฟล์เดิมแล้ว\n' "$h" "$(get PM2)"
            [ -n "$(get WHY)" ] && printf '                 สาเหตุ: %s\n' "$(get WHY)"
            bad=$((bad + 1))
        else
            printf '%-16s อัปเดตแล้ว [ไฟล์มาจาก %s] (สิทธิ์ %s, pm2 %s, เวลา %s)\n' \
                "$h" "$(get GOTFILES)" "$(get SUDOERS)" "$(get PM2)" "$(get TIME)"
            ok=$((ok + 1))
        fi
        ;;
    verify)
        epoch=$(get EPOCH); now=$(date +%s)
        diff=$(( epoch > now ? epoch - now : now - epoch ))
        problems=""
        [ "$(get TIMESYNC)" = yes ] || problems="$problems ไม่มี timeSync.js"
        [ "$(get SUDOOK)" = yes ] || problems="$problems สิทธิ์ใช้ไม่ได้"
        [ "$(get PM2)" = online ] || problems="$problems pm2 ไม่ online"
        [ "$diff" -le 60 ] || problems="$problems เวลาต่าง ${diff}s"
        [ "$(get TZ)" = "+0700" ] || problems="$problems timezone $(get TZ)"
        if [ -z "$problems" ]; then
            printf '%-16s พร้อมใช้งาน (เวลาต่าง %ss, ซิงก์มาแล้ว %s ครั้ง)\n' "$h" "$diff" "$(get SYNCED)"
            ok=$((ok + 1))
        else
            printf '%-16s ยังไม่พร้อม:%s\n' "$h" "$problems"
            bad=$((bad + 1))
        fi
        ;;
    esac
done

echo
echo "เรียบร้อย $ok ตัว, มีปัญหา $bad ตัว (จาก ${#HOSTS[@]})"
[ "$MODE" = status ] && echo "พอใจแล้วสั่ง: bash fleet-timesync.sh --apply"
[ "$MODE" = apply ] && echo "ตรวจผล: bash fleet-timesync.sh --verify"
[ "$bad" -eq 0 ]
