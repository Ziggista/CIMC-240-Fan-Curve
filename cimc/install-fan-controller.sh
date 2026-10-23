#!/bin/sh
# Fixed-purpose installer invoked once on the CIMC as root.

set -e

BASE=/mnt/jffs2
RUN=/var/service/rack_fan_control/run

chmod 755 "$BASE/custom-fan-curve.sh" "$BASE/fanboot.trigger" "$BASE/rollback-fan-controller.sh"
cp "$BASE/fanboot.trigger" "$BASE/nihuu_delay_cimc_reboot"
chmod 755 "$BASE/nihuu_delay_cimc_reboot"
rm -f "$BASE/fanboot.disabled"
touch "$BASE/host_reboot_flag"

if [ -L "$RUN" ]; then
  readlink "$RUN" > "$BASE/native-fan-run-target"
fi

rm -f "$RUN"
printf '#!/bin/sh\nexec sh /mnt/jffs2/custom-fan-curve.sh\n' > "$RUN"
chmod 755 "$RUN"

date > "$BASE/fan-controller-installed"
killall rack_fan_control 2>/dev/null || true
exit 0
