#!/vendor/bin/sh
# Keep kernel and Android logs of the last few boots on /metadata/spx-debug,
# where Fedora can read them after a failed boot (tools/read-bootlog.sh).
#
#   spx-bootlog.sh boot    started at init: snapshots every 3 s for 10 min
#   spx-bootlog.sh final   started at boot completion: one last snapshot
#   spx-bootlog.sh shutdown run by init when it starts to reboot or power off
#
# logcat and ip live in /system/bin, which is not on a vendor script's PATH.

BASE=/metadata/spx-debug
KEEP=5

snapshot() {
    dmesg > "$DIR/dmesg.txt" 2>&1
    /system/bin/logcat -d -b all -v threadtime > "$DIR/logcat.txt" 2>&1
    getprop > "$DIR/props.txt" 2>&1
    {
        date
        cat /proc/uptime
        echo "--- services"
        getprop | grep 'init.svc\.'
        echo "--- mounts"
        cat /proc/mounts
        echo "--- remoteproc"
        for r in /sys/class/remoteproc/*; do
            [ -e "$r/name" ] && echo "$(cat "$r/name"): $(cat "$r/state")"
        done
        echo "--- network"
        /system/bin/ip addr 2>&1
    } > "$DIR/status.txt" 2>&1
    sync
}

# Where processes that matter during bring-up are stuck: user-space backtraces
# (debuggerd) and kernel stacks. Written to hangs.N.txt.
HANG_PATTERNS="audio.service-aidl audioserver system_server"
hang_dump() {
    {
        date
        cat /proc/uptime
        echo "--- sound cards"
        cat /proc/asound/cards 2>&1
        ls -l /dev/snd 2>&1
        for c in /proc/[0-9]*/cmdline; do
            pid=${c#/proc/}
            pid=${pid%/cmdline}
            cmd=$(tr '\0' ' ' < "$c" 2>/dev/null)
            for p in $HANG_PATTERNS; do
                case "$cmd" in
                    *"$p"*)
                        echo "=== pid $pid: $cmd"
                        for t in /proc/"$pid"/task/*; do
                            echo "--- tid ${t##*/} $(cat "$t/comm" 2>/dev/null) wchan=$(cat "$t/wchan" 2>/dev/null)"
                            cat "$t/stack" 2>/dev/null
                        done
                        /system/bin/debuggerd -b "$pid" 2>&1
                        break ;;
                esac
            done
        done
    } > "$DIR/hangs.$1.txt" 2>&1
    sync
}

mkdir -p "$BASE" || exit 0

case "$1" in
    boot)
        # Rotate: boot.1 is this boot, boot.2 the one before, ...
        i=$KEEP
        rm -rf "$BASE/boot.$i"
        while [ "$i" -gt 1 ]; do
            prev=$((i - 1))
            [ -d "$BASE/boot.$prev" ] && mv "$BASE/boot.$prev" "$BASE/boot.$i"
            i=$prev
        done
        DIR="$BASE/boot.1"
        mkdir -p "$DIR"
        n=0
        while [ "$n" -lt 200 ]; do
            snapshot
            [ "$(getprop sys.boot_completed)" = 1 ] && break
            # After about 1.5 and 5 minutes, record where things are stuck.
            case "$n" in 30|100) hang_dump "$n" ;; esac
            sleep 3
            n=$((n + 1))
        done
        ;;
    final)
        DIR="$BASE/boot.1"
        mkdir -p "$DIR"
        snapshot
        echo "boot completed" > "$DIR/COMPLETED"
        sync
        ;;
    shutdown)
        DIR="$BASE/boot.1"
        mkdir -p "$DIR"
        snapshot
        {
            date
            cat /proc/uptime
            getprop sys.powerctl
            getprop sys.boot.reason
        } > "$DIR/SHUTDOWN" 2>&1
        sync
        ;;
esac
exit 0
