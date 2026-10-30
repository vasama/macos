# macos-vm

On-demand SSH access to a GitHub-hosted macOS runner, for trying things out on
macOS. A manually started workflow boots a runner, starts an SSH server on it
and exposes it through a Cloudflare quick tunnel. You need no Cloudflare account and no repository secrets.

## Setup

1. Push this repository to GitHub.
2. Make sure your SSH public key is on your GitHub account
   (<https://github.com/settings/keys>). The session authorizes the keys
   published at `https://github.com/<you>.keys` for whoever starts the run.
   To allow more keys, put `authorized_keys` lines in a repository variable
   named `SSH_AUTHORIZED_KEYS` (Settings → Secrets and variables → Actions →
   Variables).
3. Install `cloudflared` on the machine you connect from
   (`brew install cloudflared`, or a binary from
   <https://github.com/cloudflare/cloudflared/releases>).

## Start a session

From the **Actions** tab, run **macOS SSH session**. Or use the CLI:

```sh
gh workflow run macos-ssh.yml -f runner=macos-15 -f minutes=90
gh run watch
```

Inputs:

| Input     | Default        | Meaning                                                   |
|-----------|----------------|-----------------------------------------------------------|
| `runner`  | `macos-latest` | Runner label, e.g. `macos-15` or `macos-14`               |
| `minutes` | `60`           | How long to keep the session open (1–350)                 |

When the **Hold session** step starts, its log shows the command to run:

```
ssh -o ProxyCommand='cloudflared access ssh --hostname %h' runner@<name>.trycloudflare.com
```

It also shows the host key fingerprint. Every session gets a new hostname and
a new host key.

## Use with scp, rsync and VS Code

Add this to `~/.ssh/config` once:

```
Host *.trycloudflare.com
  User runner
  ProxyCommand cloudflared access ssh --hostname %h
```

After that, the plain hostname works everywhere:

```sh
ssh <name>.trycloudflare.com
scp build.tar.gz <name>.trycloudflare.com:
rsync -a ./project/ <name>.trycloudflare.com:project/
```

In VS Code, use **Remote-SSH: Connect to Host…** with the same hostname.

## End a session

The session ends when any of these happens:

- the time limit runs out,
- you run `touch ~/end-session` on the runner,
- you cancel the run (`gh run cancel <id>` or from the Actions tab).

The VM is discarded afterwards. Nothing carries over to the next session, so
copy off anything you want to keep.

## How it works

- `scripts/start-sshd.sh` starts a separate `sshd` that listens only on
  `127.0.0.1:2222`. It accepts public-key logins for the `runner` user only,
  with password and keyboard-interactive authentication disabled. The
  system's own SSH configuration is not used or changed.
- `scripts/start-tunnel.sh` runs `cloudflared tunnel --url ssh://127.0.0.1:2222`
  and records the random `*.trycloudflare.com` hostname it gets.
- `scripts/hold-session.sh` keeps the job running and reprints the connection
  details every 5 minutes. If `sshd` or `cloudflared` exits, it stops the job
  so you aren't billed for a session nobody can reach.

The hostname appears in the job log, so on a public repository anyone can see
it. They still need one of the authorized private keys to log in. Anyone with
write access to the repository can start a session with their own keys.

## Limits

- GitHub-hosted jobs run for at most 6 hours.
- On private repositories, macOS minutes use up your Actions quota much faster
  than Linux minutes do. Standard runners are free on public repositories.
- You get a terminal only, with no GUI. `macos-latest` and `macos-14`/`15` are
  Apple Silicon.
- Quick tunnels have no uptime guarantee. If a session drops, start a new one.
- GitHub's terms allow Actions use for building and testing software. Use these
  sessions for working on your projects, not as a general-purpose remote Mac.
