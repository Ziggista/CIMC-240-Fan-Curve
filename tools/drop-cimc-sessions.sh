#!/usr/bin/env bash
# drop-cimc-sessions.sh
#
# Terminate stale Cisco CIMC user sessions to free the limited (4) session
# pool. Unlike the scripts in cimc/, this one runs FROM an admin workstation
# and drives the CIMC's SSH CLI remotely.
#
# It lists the open user sessions, then terminates the ones CIMC marks
# "Killable". Your own current session is never Killable, so it is left alone.
# This is best-effort: it can only connect while at least one session slot is
# free, which is usually the point of running it.
#
# Environment:
#   CIMC_HOST      CIMC address          (default 192.168.1.105)
#   CIMC_USER      CIMC username         (default admin)
#   CIMC_SSH_OPTS  extra ssh options     (e.g. "-i $HOME/.ssh/cimc_key")
#   DRY_RUN=1      list sessions only, do not terminate anything
#   FORCE_ALL=1    if no Killable column is parsed from the listing, attempt
#                  every listed session ID anyway (CIMC still refuses to kill
#                  your current session)
set -euo pipefail

CIMC_HOST="${CIMC_HOST:-192.168.1.105}"
CIMC_USER="${CIMC_USER:-admin}"
CIMC_SSH_OPTS="${CIMC_SSH_OPTS:-}"
DRY_RUN="${DRY_RUN:-0}"
FORCE_ALL="${FORCE_ALL:-0}"

# CIMC's CLI needs a PTY (-tt); commands are fed on stdin and the session ends
# at EOF. Word-splitting of CIMC_SSH_OPTS is intentional.
ssh_cimc() {
  # shellcheck disable=SC2086
  ssh -tt -o StrictHostKeyChecking=accept-new ${CIMC_SSH_OPTS} \
    "${CIMC_USER}@${CIMC_HOST}"
}

echo "== Current sessions on ${CIMC_HOST} =="
listing="$(printf 'show user-session\n' | ssh_cimc 2>/dev/null || true)"
printf '%s\n' "${listing}"

# Table columns: ID  Name  IP Address  Type  Killable
killable_ids="$(printf '%s\n' "${listing}" \
  | awk '$1 ~ /^[0-9]+$/ && tolower($NF) ~ /^yes/ { print $1 }')"
all_ids="$(printf '%s\n' "${listing}" \
  | awk '$1 ~ /^[0-9]+$/ { print $1 }')"

ids="${killable_ids}"
if [ -z "${ids}" ] && [ "${FORCE_ALL}" = "1" ]; then
  ids="${all_ids}"
fi

if [ -z "${ids}" ]; then
  if [ -n "${all_ids}" ]; then
    echo
    echo "No sessions flagged Killable. Re-run with FORCE_ALL=1 to attempt all:"
    # shellcheck disable=SC2086
    printf '  %s\n' ${all_ids}
  else
    echo "No sessions to terminate (list empty or unavailable)."
  fi
  exit 0
fi

echo
echo "== Terminating sessions: ${ids} =="
if [ "${DRY_RUN}" = "1" ]; then
  echo "DRY_RUN=1: not terminating."
  exit 0
fi

{
  for id in ${ids}; do
    printf 'scope user-session %s\n' "${id}"
    printf 'terminate\n'
    printf 'top\n'
  done
} | ssh_cimc 2>/dev/null || true

echo
echo "== Sessions after termination =="
printf 'show user-session\n' | ssh_cimc 2>/dev/null || true
