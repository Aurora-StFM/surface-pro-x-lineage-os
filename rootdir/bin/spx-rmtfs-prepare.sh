#!/vendor/bin/sh
# Create the zero-filled EFS images rmtfs serves to the modem, if missing.
# Same as the Fedora port's rmtfs-prepare (linux-surface rmtfs-dummy).
dir=/data/vendor/rmtfs
mkdir -p "$dir"
for f in modem_fs1 modem_fs2 modem_fsc modem_fsg modem_tuning; do
    [ -s "$dir/$f" ] || truncate -s 2M "$dir/$f"
done
exit 0
