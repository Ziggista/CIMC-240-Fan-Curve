#!/bin/sh
# Persistent HUU-init trampoline for the custom fan controller.

[ -e /mnt/jffs2/fanboot.disabled ] && exit 0

D=$(printf 'de%s' lay)
TRIGGER="/mnt/jffs2/nihuu_${D}_cimc_reboot"

# Re-arm the one-shot HUU trigger for the next CIMC boot.
cp /mnt/jffs2/fanboot.trigger "$TRIGGER" 2>/dev/null
chmod 755 "$TRIGGER" 2>/dev/null
touch /mnt/jffs2/host_reboot_flag

i=0
while [ "$i" -lt 60 ]; do
  if [ -d /var/service/rack_fan_control ]; then
    if [ -L /var/service/rack_fan_control/run ] && [ ! -s /mnt/jffs2/native-fan-run-target ]; then
      readlink /var/service/rack_fan_control/run > /mnt/jffs2/native-fan-run-target
    fi
    rm -f /var/service/rack_fan_control/run
    printf '#!/bin/sh\nexec sh /mnt/jffs2/custom-fan-curve.sh\n' > /var/service/rack_fan_control/run
    chmod 755 /var/service/rack_fan_control/run
    killall rack_fan_control 2>/dev/null
    exit 0
  fi
  sleep 1
  i=$((i + 1))
done

exit 1
