#!/bin/sh
# Disable persistence and restore the native supervised fan service at runtime.

BASE=/mnt/jffs2
RUN=/var/service/rack_fan_control/run

touch "$BASE/fanboot.disabled"
rm -f "$BASE/host_reboot_flag" "$BASE/nihuu_delay_cimc_reboot"

# Move to full cooling before handing PWM control back to Cisco.
for controller in 0 1 4 5 6 7; do
  /usr/local/bin/pwmtest setdutycycle "$controller" 100 >/dev/null 2>&1
done

if [ -s /tmp/custom-fan-curve.pid ]; then
  kill "$(cat /tmp/custom-fan-curve.pid)" 2>/dev/null
fi

rm -f "$RUN"
if [ -s "$BASE/native-fan-run-target" ]; then
  ln -s "$(cat "$BASE/native-fan-run-target")" "$RUN"
fi

exit 0
