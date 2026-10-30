# macOS SSH Action

Action for hosting an interactive session using on a GitHub-hosted macOS runner.

> [!CAUTION]
> This action may only be used for development of GitHub hosted projects and not
> as a general purpose macOS virtual machine.

## Quick start

1. Add the session workflow to your repository, then commit and push it:

   ```sh
   mkdir -p .github/workflows
   curl -fsSLo .github/workflows/macos-ssh.yml \
     https://raw.githubusercontent.com/vasama/macos/v1/user-workflow.yml
   ```
2. Make sure your SSH public key is on your GitHub account
   (<https://github.com/settings/keys>). The session authorizes the keys
   published at `https://github.com/<you>.keys` for whoever starts the run.
   To allow more keys, put `authorized_keys` lines in a repository variable
   named `SSH_AUTHORIZED_KEYS` (Settings → Secrets and variables → Actions →
   Variables).
3. Install `cloudflared` on the machine you connect from
   (`brew install cloudflared`, or a binary from
   <https://github.com/cloudflare/cloudflared/releases>).
4. Start a session from your repository's **Actions** tab (**macOS SSH
   session** → **Run workflow**), or with the CLI:

   ```sh
   gh workflow run macos-ssh.yml -f runner=macos-15 -f timeout=90
   gh run watch
   ```

Once the session is up, the CI step shows the command to run:
```
ssh -o ProxyCommand='cloudflared access ssh --hostname %h' runner@<name>.trycloudflare.com
```

To end the session, use the `end-session` command while logged in.

> [!WARNING]
> When the session ends, the VM is discarded and any files created during the
> session are lost.

## Debugging an existing job

The action works as a step in any macOS job. For example, to log into a CI job
right after it fails, with its build state still in place:

```yaml
- uses: vasama/macos@v1
  if: failure()
  with:
    timeout: 30
```

## Connecting with VS Code

Add this to `~/.ssh/config` once:

```
Host macos-runner
  HostName *.trycloudflare.com
  ProxyCommand cloudflared access ssh --hostname %h
  User runner
```

In VS Code, use **Remote-SSH: Connect to Host…** and select `macos-runner`.

### Inputs

| Input             | Default                          | Meaning                                               |
|-------------------|----------------------------------|-------------------------------------------------------|
| `timeout`         | `60`                             | How long to keep the session open, in minutes (1–350) |
| `github-user`     | `${{ github.triggering_actor }}` | GitHub user whose published SSH keys may log in       |
| `authorized-keys` | empty                            | Additional `authorized_keys` lines that may log in    |

## Limitations

- GitHub-hosted jobs run for at most 6 hours.
- On private repositories, macOS minutes use up your Actions quota much faster
  than Linux minutes do. Standard runners are free on public repositories.
- Quick tunnels have no uptime guarantee. If a session drops, start a new one.
