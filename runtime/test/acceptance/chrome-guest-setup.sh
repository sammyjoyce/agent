#!/bin/bash
# Runs inside the disposable macOS guest as its auto-login user.
# Usage: chrome-guest-setup.sh BEEP_BOOP_STORE_PATH REX_STORE_PATH WORKER_AGENT_JSON
# WORKER_AGENT_JSON is the LaunchAgent nix/module.nix declares (module-agent.nix).
set -euo pipefail

beep_boop=$1
rex=$2
worker_agent=$3
lab=$HOME/lab
agents=$HOME/Library/LaunchAgents
uid=$(id -u)
chrome_root=$HOME/BeepBoopChrome

[[ -x $beep_boop/bin/beep-boop ]] || { echo "Missing Beep Boop package $beep_boop" >&2; exit 1; }
[[ -x $rex/bin/rex ]] || { echo "Missing Rex package $rex" >&2; exit 1; }
[[ -f $worker_agent ]] || { echo "Missing worker agent $worker_agent" >&2; exit 1; }
[[ -d "/Applications/Google Chrome.app" ]] || { echo "Install Google Chrome first" >&2; exit 1; }

umask 077
mkdir -p "$lab/state" "$lab/rex-state" "$lab/secrets" "$lab/logs" "$HOME/.ssh" "$agents" "$chrome_root"
/nix/var/nix/profiles/default/bin/nix profile list --profile /nix/var/nix/profiles/default 2>/dev/null | grep -qF "$rex" ||
  sudo /nix/var/nix/profiles/default/bin/nix profile add --profile /nix/var/nix/profiles/default "$rex"

[[ -f $HOME/.ssh/lab_self ]] || ssh-keygen -q -t ed25519 -N "" -C chrome-guest-self -f "$HOME/.ssh/lab_self"
touch "$HOME/.ssh/authorized_keys"
grep -qF "$(cat "$HOME/.ssh/lab_self.pub")" "$HOME/.ssh/authorized_keys" || cat "$HOME/.ssh/lab_self.pub" >> "$HOME/.ssh/authorized_keys"
cat > "$HOME/.ssh/config" <<EOF
Host lab-coordinator
  HostName 127.0.0.1
  User $(id -un)
  IdentityFile ~/.ssh/lab_self
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
EOF
cat > "$lab/coordinator-rpc" <<EOF
#!/bin/sh
exec /usr/bin/nc -U $lab/coordinator.sock
EOF
cat > "$lab/browser-credentials" <<EOF
#!/bin/sh
PLAYWRIGHT_MCP_EXTENSION_TOKEN="\$(cat $lab/secrets/playwright-token)"
export PLAYWRIGHT_MCP_EXTENSION_TOKEN
exec "\$@"
EOF
chmod 700 "$lab/coordinator-rpc" "$lab/browser-credentials"

cat > "$lab/config.toml" <<EOF
node_name = "chrome-guest"
coordinator = "lab-coordinator"
coordinator_program = "$lab/coordinator-rpc"
context_repositories = []
job_directories = []
sources = []

[browser]
user_data_dir = "$chrome_root"
profile_dir_name = "Default"
credential_command = ["$lab/browser-credentials"]
EOF

xml() { local value=${1//&/&amp;}; value=${value//</&lt;}; printf '%s' "${value//>/&gt;}"; }

plist() {
  local label=$1 keep_alive=$2
  shift 2
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n'
    printf '<key>Label</key><string>%s</string>\n<key>ProgramArguments</key><array>\n' "$label"
    for argument in "$@"; do printf '<string>%s</string>\n' "$(xml "$argument")"; done
    printf '</array>\n<key>RunAtLoad</key><true/>\n<key>KeepAlive</key><%s/>\n' "$keep_alive"
    printf '<key>ThrottleInterval</key><integer>10</integer>\n<key>ProcessType</key><string>Interactive</string>\n'
    printf '<key>WorkingDirectory</key><string>%s</string>\n' "$HOME"
    printf '<key>StandardOutPath</key><string>%s/logs/%s.log</string>\n<key>StandardErrorPath</key><string>%s/logs/%s.log</string>\n' "$lab" "$label" "$lab" "$label"
    printf '</dict></plist>\n'
  } > "$agents/$label.plist"
}

plist acceptance.rex true /bin/sh -c '/bin/wait4path /nix/store && exec "$@"' rex "$rex/bin/rex" server run --state-dir "$lab/rex-state"
cp "$worker_agent" "$lab/org.nixos.agent.json"
plutil -convert xml1 -o "$agents/org.nixos.agent.plist" "$lab/org.nixos.agent.json"
plutil -insert StandardOutPath -string "$lab/logs/agent.log" "$agents/org.nixos.agent.plist"
plutil -insert StandardErrorPath -string "$lab/logs/agent.log" "$agents/org.nixos.agent.plist"
plist acceptance.chrome false /usr/bin/open -a "Google Chrome" --args "--user-data-dir=$chrome_root" --remote-debugging-port=9333 --no-first-run --no-default-browser-check
# loginwindow reopens the apps in its saved list before login agents run, and
# shutdown -r never rewrites that list. A reopened Chrome has no lab arguments,
# so open would find it running. Lock the list empty; the launcher owns Chrome.
persistent="$HOME/Library/Group Containers/group.com.apple.loginwindow.persistent-apps/persistantApps"
mkdir -p "$(dirname "$persistent")"
[[ ! -e $persistent ]] || chflags nouchg "$persistent"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0"><dict><key>PersistentApps</key><array/></dict></plist>' > "$persistent"
chflags uchg "$persistent"

for label in acceptance.rex org.nixos.agent acceptance.chrome; do
  launchctl bootout "gui/$uid/$label" 2>/dev/null || true
  # bootout can return while launchd still holds the job, and bootstrap then fails with error 5.
  for _ in $(seq 1 100); do launchctl print "gui/$uid/$label" >/dev/null 2>&1 || break; sleep 0.1; done
  launchctl bootstrap "gui/$uid" "$agents/$label.plist"
done
echo "guest setup complete"
