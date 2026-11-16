#!/bin/bash
# Reboots the provisioned guest N times. After each boot, waits for automatic
# login and records whether the module's worker agent is running. Exits nonzero
# if any boot left it stopped.
# Usage: guest-reboot-trials.sh N [EVIDENCE_FILE]
set -euo pipefail

trials=${1:?trial count}
evidence=${2:-/dev/stdout}
lab=${CHROME_GUEST_LAB:-$HOME/.chrome-guest-lab}
settle=${CHROME_GUEST_SETTLE_SECONDS:-60}
guest() { ssh -F "$lab/ssh_config" -o ConnectTimeout=3 guest "$@"; }
boot_time() { guest 'sysctl -n kern.boottime' 2>/dev/null | sed -E 's/^\{ sec = ([0-9]+),.*/\1/'; }

failed=0
for trial in $(seq 1 "$trials"); do
  before=$(boot_time)
  guest 'sudo shutdown -r now' >/dev/null 2>&1 || true
  after=$before
  for _ in $(seq 1 100); do
    sleep 3
    after=$(boot_time) || continue
    [[ -n $after && $after != "$before" ]] && break
  done
  [[ $after != "$before" ]] || { echo "trial $trial: the guest did not reboot" >&2; exit 1; }
  for _ in $(seq 1 40); do guest 'who | grep -q console' && break; sleep 3; done
  sleep "$settle"
  state=$(guest 'launchctl print gui/$(id -u)/org.nixos.agent' | awk '
    /^\tstate = / { state = $3 }
    /^\tpid = / { pid = $3 }
    /last exit code = / { sub(/.*last exit code = /, ""); code = $0 }
    END { printf "%s|%s|%s", state, pid, code }')
  IFS='|' read -r agent_state agent_pid agent_exit <<< "$state"
  console=$(guest 'who | awk "/console/ {print \$1}"')
  running=false
  [[ $agent_state == running && -n $agent_pid ]] && running=true
  $running || failed=$((failed + 1))
  printf '{"trial":%d,"boot_before":%s,"boot_after":%s,"console_user":"%s","agent_state":"%s","agent_pid":"%s","agent_last_exit":"%s","agent_running":%s}\n' \
    "$trial" "$before" "$after" "$console" "$agent_state" "$agent_pid" "$agent_exit" "$running" >> "$evidence"
done
echo "$((trials - failed))/$trials boots started the worker agent" >&2
[[ $failed -eq 0 ]]
