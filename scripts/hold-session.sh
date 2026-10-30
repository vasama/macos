#!/usr/bin/env bash
# Keep the job, and with it the VM, alive until the time limit is reached,
# someone runs `touch ~/end-session` on the runner, or sshd or the tunnel dies.
# Reprints the connection details every few minutes so they stay at the
# bottom of the live log. On exit, stops sshd and the tunnel so that later
# steps in the job run without remote access.
#
# Environment:
#   MINUTES        how long to keep the session open, 1-350 (default 60)
#   SSH_STATE_DIR  shared with start-sshd.sh (default ~/.macos-vm-ssh)
set -euo pipefail

minutes="${MINUTES:-60}"
state_dir="${SSH_STATE_DIR:-$HOME/.macos-vm-ssh}"
stop_file="$HOME/end-session"

if ! [[ "$minutes" =~ ^[0-9]+$ ]] || (( minutes < 1 || minutes > 350 )); then
  echo "::error::MINUTES must be a whole number from 1 to 350, got '$minutes'"
  exit 1
fi

host="$(cat "$state_dir/host")"
host_fingerprint="$(cat "$state_dir/host_fingerprint")"
user="$(id -un)"
end=$(( $(date +%s) + minutes * 60 ))
rm -f "$stop_file"

stop_access() {
  kill "$(cat "$state_dir/cloudflared.pid")" 2>/dev/null || true
  sudo kill "$(cat "$state_dir/sshd.pid")" 2>/dev/null || true
}
trap stop_access EXIT

print_info() {
  local left=$(( (end - $(date +%s) + 59) / 60 ))
  cat <<EOF
==========================================================================
Connect with:

  ssh -o ProxyCommand='cloudflared access ssh --hostname %h' $user@$host

Host key: $host_fingerprint
Workspace: ${GITHUB_WORKSPACE:-n/a}
Session ends in about $left min. End it early with: touch ~/end-session
==========================================================================
EOF
}

next_info=0
while (( $(date +%s) < end )); do
  if [[ -e "$stop_file" ]]; then
    echo "Session ended with ~/end-session."
    exit 0
  fi
  for proc in sshd cloudflared; do
    if ! ps -p "$(cat "$state_dir/$proc.pid")" > /dev/null; then
      echo "::error::$proc exited; the session is no longer reachable."
      tail -n 50 "$state_dir/$proc.log" || true
      exit 1
    fi
  done
  if (( $(date +%s) >= next_info )); then
    print_info
    next_info=$(( $(date +%s) + 300 ))
  fi
  sleep 5
done
echo "Time limit of $minutes min reached."
