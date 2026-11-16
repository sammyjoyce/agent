#!/bin/bash
# Provisions the disposable macOS guest for Chrome lifecycle acceptance.
# Safe to rerun: each step checks the guest before changing it.
#
# Environment (defaults in brackets):
#   CHROME_GUEST_LAB   private outer-host directory for keys and ssh config [~/.chrome-guest-lab]
#   CHROME_GUEST_VM    Tart VM name [chrome-acceptance-guest]
#   CHROME_GUEST_IMAGE Tart image [ghcr.io/cirruslabs/macos-tahoe-vanilla:26.6.2]
#   TART_HOME          Tart storage for this lab only [$CHROME_GUEST_LAB/tart]
#   BEEP_BOOP          packaged Beep Boop store path [nix build .#beep-boop]
#   REX                Rex store path [resolved from `command -v rex`]
set -euo pipefail

lab=${CHROME_GUEST_LAB:-$HOME/.chrome-guest-lab}
vm=${CHROME_GUEST_VM:-chrome-acceptance-guest}
image=${CHROME_GUEST_IMAGE:-ghcr.io/cirruslabs/macos-tahoe-vanilla:26.6.2}
export TART_HOME=${TART_HOME:-$lab/tart}
here=$(cd "$(dirname "$0")" && pwd)
repository=$(cd "$here/../../.." && pwd)

mkdir -p "$lab" "$TART_HOME"
chmod 700 "$lab"
tart=$(NIXPKGS_ALLOW_UNFREE=1 nix build --impure --no-link --print-out-paths nixpkgs#tart)/bin/tart
beep_boop=${BEEP_BOOP:-$(nix build --no-link --print-out-paths "$repository#beep-boop")}
rex=${REX:-$(dirname "$(dirname "$(readlink -f "$(command -v rex)")")")}
[[ -x $rex/bin/rex ]] || { echo "Set REX to a Rex store path" >&2; exit 1; }

if ! "$tart" get "$vm" >/dev/null 2>&1; then
  "$tart" clone "$image" "$vm"
  "$tart" set "$vm" --cpu 4 --memory 8192
fi
if [[ $("$tart" get "$vm" --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["State"])') != running ]]; then
  nohup "$tart" run --no-graphics "$vm" > "$lab/tart-run.log" 2>&1 < /dev/null &
  echo $! > "$lab/tart-run.pid"
fi
address=$("$tart" ip --wait 120 "$vm")

[[ -f $lab/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N "" -C chrome-guest-lab -f "$lab/id_ed25519"
cat > "$lab/ssh_config" <<EOF
Host guest
  HostName $address
  User admin
  IdentityFile $lab/id_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
  ServerAliveInterval 5
EOF
guest() { ssh -F "$lab/ssh_config" guest "$@"; }
for _ in $(seq 1 60); do guest true 2>/dev/null && break || true; sleep 2
  # The Tart image ships with password login for admin; it authorizes this lab key once.
  nix shell nixpkgs#sshpass -c sshpass -p admin ssh -o PubkeyAuthentication=no \
    -o PreferredAuthentications=password,keyboard-interactive -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "admin@$address" \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$(cat "$lab/id_ed25519.pub")' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" 2>/dev/null || true
done
guest true

guest 'test -d "/Applications/Google Chrome.app"' || guest 'set -e; cd /tmp
  curl -sSfL -o chrome.dmg https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg
  hdiutil attach -nobrowse -quiet -mountpoint /tmp/chromedmg chrome.dmg
  sudo ditto "/tmp/chromedmg/Google Chrome.app" "/Applications/Google Chrome.app"
  hdiutil detach -quiet /tmp/chromedmg; rm chrome.dmg'

guest 'test -x /nix/var/nix/profiles/default/bin/nix' || guest 'curl -fsSL https://install.determinate.systems/nix -o /tmp/nix-install.sh &&
  sh /tmp/nix-install.sh install --no-confirm --extra-conf "trusted-users = root admin"'
# An encrypted Nix volume makes macOS ask for its password at every login.
guest 'set -e; disk=$(diskutil info -plist /nix | plutil -extract DeviceIdentifier raw -)
  if diskutil apfs list | grep -A12 "Nix Store" | grep -q "FileVault:.*Yes"; then
    uuid=$(diskutil info -plist /nix | plutil -extract VolumeUUID raw -)
    passphrase=$(sudo security find-generic-password -a "$uuid" -w /Library/Keychains/System.keychain ||
      sudo security find-generic-password -s "Nix Store" -w /Library/Keychains/System.keychain)
    sudo diskutil apfs decryptVolume "$disk" -user disk -passphrase "$passphrase"
  fi'
NIX_SSHOPTS="-F $lab/ssh_config" nix copy --no-check-sigs \
  --to "ssh-ng://guest?remote-program=/nix/var/nix/profiles/default/bin/nix-daemon" "$beep_boop" "$rex"

nix eval --json --impure --expr "import $here/module-agent.nix {
  flake = builtins.getFlake \"git+file://$repository\"; package = \"$beep_boop\";
  configFile = \"/Users/admin/lab/config.toml\"; stateDirectory = \"/Users/admin/lab/state\"; }" > "$lab/worker-agent.json"
scp -F "$lab/ssh_config" -q "$here/chrome-guest-setup.sh" guest:/tmp/chrome-guest-setup.sh
scp -F "$lab/ssh_config" -q "$lab/worker-agent.json" guest:/tmp/worker-agent.json
guest "bash /tmp/chrome-guest-setup.sh '$beep_boop' '$rex' /tmp/worker-agent.json"
printf 'guest=%s\naddress=%s\nbeep_boop=%s\nrex=%s\ntart=%s\n' "$vm" "$address" "$beep_boop" "$rex" "$tart" > "$lab/guest.env"
echo "Guest $vm is ready at $address; see $lab/guest.env"
