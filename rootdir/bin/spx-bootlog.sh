#!/vendor/bin/sh
# Keep kernel and Android logs of the last few boots on /metadata/spx-debug,
# where Fedora can read them after a failed boot (tools/read-bootlog.sh).
#
#   spx-bootlog.sh boot    started at post-fs: snapshots every 10 s for 10 min
#   spx-bootlog.sh final   started at boot completion: one last snapshot

BASE=/metadata/spx-debug
KEEP=5

snapshot() {
    dmesg > "$DIR/dmesg.txt" 2>&1
    logcat -d -b all -v threadtime > "$DIR/logcat.txt" 2>&1
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
        ip addr 2>&1
    } > "$DIR/status.txt" 2>&1
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
        while [ "$n" -lt 60 ]; do
            snapshot
            [ "$(getprop sys.boot_completed)" = 1 ] && break
            sleep 10
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
esac
exit 0
