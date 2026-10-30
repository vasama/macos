#!/usr/bin/env bash
# Expose the local sshd through a Cloudflare quick tunnel (no account needed)
# and record the tunnel's hostname.
#
# Environment:
#   SSH_PORT       port sshd listens on (default 2222)
#   SSH_STATE_DIR  shared with start-sshd.sh (default ~/.macos-vm-ssh)
set -euo pipefail

port="${SSH_PORT:-2222}"
state_dir="${SSH_STATE_DIR:-$HOME/.macos-vm-ssh}"
log="$state_dir/cloudflared.log"

nohup cloudflared tunnel --no-autoupdate --url "ssh://127.0.0.1:$port" > "$log" 2>&1 &
pid=$!
echo "$pid" > "$state_dir/cloudflared.pid"

# cloudflared prints the hostname first and can take a few more seconds to
# register a connection with Cloudflare's edge.
host=""
for _ in $(seq 60); do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "::error::cloudflared exited before the tunnel was ready"
    cat "$log"
    exit 1
  fi
  if [[ -z "$host" ]]; then
    host="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$log" | grep -v '^https://api\.' | head -n 1 | sed 's|^https://||')" || true
  fi
  if [[ -n "$host" ]] && grep -q 'Registered tunnel connection' "$log"; then
    break
  fi
  sleep 1
done

if [[ -z "$host" ]]; then
  echo "::error::cloudflared did not report a tunnel hostname"
  cat "$log"
  exit 1
fi
if ! grep -q 'Registered tunnel connection' "$log"; then
  echo "::warning::cloudflared has not registered a connection yet; the first connect attempt may fail"
fi

echo "$host" > "$state_dir/host"
echo "Tunnel: $host -> 127.0.0.1:$port"
