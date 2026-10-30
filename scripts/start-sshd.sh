#!/usr/bin/env bash
# Start a private sshd on 127.0.0.1 that only accepts public-key logins for
# the current user. It is reachable from outside only through the tunnel
# opened by start-tunnel.sh.
#
# Environment:
#   AUTHORIZED_GITHUB_USER  GitHub account whose published SSH keys may log in
#   EXTRA_AUTHORIZED_KEYS   more authorized_keys lines (optional)
#   SSH_PORT                local port to listen on (default 2222)
#   SSH_STATE_DIR           keys, config and logs (default ~/.macos-vm-ssh)
set -euo pipefail

port="${SSH_PORT:-2222}"
state_dir="${SSH_STATE_DIR:-$HOME/.macos-vm-ssh}"
user="$(id -un)"

mkdir -p "$state_dir"
chmod 700 "$state_dir"

keys="$state_dir/authorized_keys"
{
  if [[ -n "${AUTHORIZED_GITHUB_USER:-}" ]]; then
    curl -fsSL --retry 3 "https://github.com/$AUTHORIZED_GITHUB_USER.keys"
    echo
  fi
  if [[ -n "${EXTRA_AUTHORIZED_KEYS:-}" ]]; then
    printf '%s\n' "$EXTRA_AUTHORIZED_KEYS"
  fi
} > "$keys"
chmod 600 "$keys"

if ! fingerprints="$(ssh-keygen -lf "$keys" 2>/dev/null)"; then
  echo "::error::No usable SSH public keys. Add one at https://github.com/settings/keys or set the SSH_AUTHORIZED_KEYS repository variable."
  exit 1
fi
echo "Authorized keys:"
echo "$fingerprints"

host_key="$state_dir/ssh_host_ed25519_key"
if [[ ! -f "$host_key" ]]; then
  ssh-keygen -q -t ed25519 -N '' -C macos-vm -f "$host_key"
fi
ssh-keygen -lf "$host_key.pub" | awk '{ print $2 }' > "$state_dir/host_fingerprint"

# UsePAM runs the account and session stacks macOS expects (pam_launchd puts
# the login in the user's launchd domain, which keychain and launchctl need).
# With password and keyboard-interactive auth off, PAM never asks for a password.
config="$state_dir/sshd_config"
cat > "$config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $host_key
PidFile $state_dir/sshd.pid
AuthorizedKeysFile $keys
AllowUsers $user
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
ClientAliveInterval 30
Subsystem sftp internal-sftp
EOF

sudo /usr/sbin/sshd -t -f "$config"
sudo /usr/sbin/sshd -f "$config" -E "$state_dir/sshd.log"
echo "sshd listening on 127.0.0.1:$port (host key $(cat "$state_dir/host_fingerprint"))"
