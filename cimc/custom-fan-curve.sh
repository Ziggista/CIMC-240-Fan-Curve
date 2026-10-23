#!/bin/sh
# Conservative fan controller for a Cisco UCS C240 M5 with passive PCIe GPUs.
# Runs on the CIMC and replaces the supervised rack_fan_control service.

PWMTEST=/usr/local/bin/pwmtest
PECI=/usr/local/bin/Peci
IPMISENSOR=/usr/local/bin/ipmi-sensor
CURL=$(command -v curl 2>/dev/null)
LOG=/tmp/custom-fan-curve.log
PIDFILE=/tmp/custom-fan-curve.pid
SNAPSHOT=/tmp/custom-fan-sensors.$$
CONTROLLERS="0 1 4 5 6 7"
INTERVAL=2
GPU_DEMAND_URL=http://192.168.1.108/duty
# Ten percent is the user-approved quiet idle floor on this chassis. Tachometer
# readings, rather than PWM percentage, are authoritative.
MIN_DUTY=10

echo $$ > "$PIDFILE"
trap 'rm -f "$SNAPSHOT" "$PIDFILE"' EXIT HUP INT TERM

valid_temp() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 0 ] && [ "$1" -le 110 ]
}

peci_temp() {
  "$PECI" temp "$1" 2>/dev/null |
    awk -F= '/IPMI_Temperature/ {gsub(/[ \t]/, "", $2); printf "%d\n", $2 + 0.5; exit}'
}

sensor_temp() {
  awk -F'|' -v wanted="$1" '
    {
      name=$1; value=$2
      gsub(/^[ \t]+|[ \t]+$/, "", name)
      gsub(/[ \t]/, "", value)
      if (name == wanted && value ~ /^[0-9.]+$/) {
        printf "%d\n", value + 0.5
        exit
      }
    }
  ' "$SNAPSHOT"
}

hottest_ddr() {
  awk -F'|' '
    {
      name=$1; value=$2
      gsub(/[ \t]/, "", name)
      gsub(/[ \t]/, "", value)
      if (name ~ /^DDR4.*_TMP$/ && value ~ /^[0-9.]+$/ && value > hottest) {
        hottest=value
      }
    }
    END { if (hottest != "") printf "%d\n", hottest + 0.5 }
  ' "$SNAPSHOT"
}

cpu_duty() {
  t=$1
  if [ "$t" -ge 85 ]; then echo 100
  elif [ "$t" -ge 80 ]; then echo 90
  elif [ "$t" -ge 75 ]; then echo 75
  elif [ "$t" -ge 70 ]; then echo 60
  elif [ "$t" -ge 65 ]; then echo 50
  elif [ "$t" -ge 60 ]; then echo 40
  else echo "$MIN_DUTY"
  fi
}

ramp_duty() {
  t=$1
  start=$2
  full=$3
  if [ "$t" -ge "$full" ]; then
    echo 100
  elif [ "$t" -le "$start" ]; then
    echo 0
  else
    echo $(( (t - start) * 100 / (full - start) ))
  fi
}

gpu_host_duty() {
  [ -n "$CURL" ] || {
    echo 30
    return
  }
  duty=$("$CURL" -fsS --connect-timeout 1 --max-time 2 "$GPU_DEMAND_URL" 2>/dev/null) || {
    # Passive GPUs must not remain at the quiet floor if host telemetry fails.
    echo 30
    return
  }
  case "$duty" in
    ''|*[!0-9]*) echo 30 ;;
    *)
      if [ "$duty" -ge 10 ] && [ "$duty" -le 100 ]; then echo "$duty"
      else echo 30
      fi
      ;;
  esac
}

set_duty() {
  requested=$1
  result=0
  for controller in $CONTROLLERS; do
    "$PWMTEST" setdutycycle "$controller" "$requested" >/dev/null 2>&1 || result=1
  done
  return "$result"
}

log_line() {
  echo "$(date '+%Y-%m-%dT%H:%M:%S') $*" >> "$LOG"
}

last_duty=100
failures=0
loops=0

while true; do
  sensor_ok=1
  "$IPMISENSOR" > "$SNAPSHOT" 2>/dev/null || sensor_ok=0

  cpu0=$(peci_temp 0x30)
  cpu1=$(peci_temp 0x31)
  mlo=$(sensor_temp MLOM_TEMP)
  pch=$(sensor_temp PCH_TEMP_SENS)
  bmc=$(sensor_temp BMC_DIE_TEMP)
  riser1=$(sensor_temp RISER1_TEMP)
  riser2=$(sensor_temp RISER2_TEMP)
  inlet1=$(sensor_temp RISER1_INLET_TMP)
  inlet2=$(sensor_temp RISER2_INLET_TMP)
  front=$(sensor_temp TEMP_SENS_FRONT)
  ddr=$(hottest_ddr)

  # Both CPU sockets and both passive-GPU airflow paths are mandatory.
  for required in "$cpu0" "$cpu1" "$riser1" "$riser2" "$inlet1" "$inlet2" "$front"; do
    valid_temp "$required" || sensor_ok=0
  done

  if [ "$sensor_ok" -ne 1 ]; then
    failures=$((failures + 1))
  else
    failures=0
  fi

  if [ "$failures" -gt 0 ]; then
    desired=100
    reason="sensor-failsafe"
  else
    [ "$cpu0" -gt "$cpu1" ] && cpu=$cpu0 || cpu=$cpu1
    desired=$(cpu_duty "$cpu")
    reason="curve"

    candidate=$(gpu_host_duty)
    [ "$candidate" -gt "$desired" ] && desired=$candidate

    for item in \
      "$mlo:65:90" \
      "$pch:55:80" \
      "$bmc:70:85" \
      "$riser1:45:65" \
      "$riser2:45:65" \
      "$inlet1:40:60" \
      "$inlet2:40:60" \
      "$front:35:45" \
      "$ddr:55:80"; do
      value=${item%%:*}
      rest=${item#*:}
      start=${rest%%:*}
      full=${rest##*:}
      if valid_temp "$value"; then
        candidate=$(ramp_duty "$value" "$start" "$full")
        [ "$candidate" -gt "$desired" ] && desired=$candidate
      fi
    done
  fi

  [ "$desired" -lt "$MIN_DUTY" ] && desired=$MIN_DUTY

  # Raise immediately. Lower gradually to avoid oscillation and sudden acoustic changes.
  if [ "$desired" -lt "$last_duty" ]; then
    duty=$((last_duty - 5))
    [ "$duty" -lt "$desired" ] && duty=$desired
  else
    duty=$desired
  fi

  if ! set_duty "$duty"; then
    set_duty 100
    duty=100
    reason="pwm-failsafe"
  fi
  last_duty=$duty

  log_line "duty=$duty desired=$desired reason=$reason cpu0=$cpu0 cpu1=$cpu1 mlo=$mlo pch=$pch bmc=$bmc riser1=$riser1 riser2=$riser2 inlet1=$inlet1 inlet2=$inlet2 front=$front ddr=$ddr"

  loops=$((loops + 1))
  if [ "$loops" -ge 120 ]; then
    tail -200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    loops=0
  fi
  sleep "$INTERVAL"
done
