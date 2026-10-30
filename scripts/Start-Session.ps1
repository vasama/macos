#!/usr/bin/env pwsh
# Open an SSH session into this machine and keep it open until it ends.
#
# Starts a private sshd on 127.0.0.1 that only accepts public-key logins for
# the current user, and exposes it through a Cloudflare quick tunnel (no
# account needed). Then keeps the job, and with it the VM, alive until the
# time limit is reached, someone runs `end-session`, or sshd or the tunnel
# dies, reprinting the connection details every few minutes so they stay at
# the bottom of the live log. On exit, stops sshd and the tunnel so that later
# steps in the job run without remote access.
#Requires -Version 7.4
[CmdletBinding()]
param(
    # GitHub account whose published SSH keys (github.com/<user>.keys) may log in.
    [string] $GitHubUser,
    # More authorized_keys lines that may log in.
    [string] $AuthorizedKeys,
    # How long to keep the session open, in minutes.
    [ValidateRange(1, 350)]
    [int] $Timeout = 60,
    # Local port for sshd.
    [ValidateRange(1, 65535)]
    [int] $Port = 2222,
    # sshd's keys, config and log, the tunnel log and the stop file.
    [string] $StateDir = (Join-Path $HOME '.macos-vm-ssh'),
    # Where to install the end-session command; /usr/local/bin is on the PATH
    # of macOS login shells.
    [string] $BinDir = '/usr/local/bin'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$User = id -un
$Workspace = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { 'n/a' }
$SshdPidFile = Join-Path $StateDir 'sshd.pid'
$SshdLog = Join-Path $StateDir 'sshd.log'
$TunnelLog = Join-Path $StateDir 'cloudflared.log'
$StopFile = Join-Path $StateDir 'stop'
$SshdPid = $null
$TunnelPid = $null

# ps rather than Get-Process: sshd runs as root, and ps sees every user's processes.
function Test-Running([string] $Id) {
    $PSNativeCommandUseErrorActionPreference = $false
    ps -p $Id *> $null
    $LASTEXITCODE -eq 0
}

function Revoke-Access {
    $PSNativeCommandUseErrorActionPreference = $false
    if ($TunnelPid) {
        Stop-Process -Id $TunnelPid -ErrorAction SilentlyContinue
    }
    if ($SshdPid) {
        sudo kill $SshdPid 2> $null
    }
}

function Write-ConnectionInfo {
    $Left = [math]::Ceiling(($End - (Get-Date)).TotalMinutes)
    Write-Host @"
==========================================================================
Connect with:

  ssh -o ProxyCommand='cloudflared access ssh --hostname %h' $User@$TunnelHost

Host key: $HostFingerprint
Workspace: $Workspace
Session ends in about $Left min. End it early with: end-session
==========================================================================
"@
}

try {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    chmod 700 $StateDir
    Remove-Item -Path $SshdPidFile, $StopFile -Force -ErrorAction SilentlyContinue

    $Keys = Join-Path $StateDir 'authorized_keys'
    $Lines = @(
        if ($GitHubUser) {
            Invoke-RestMethod -Uri "https://github.com/$GitHubUser.keys" -MaximumRetryCount 3
        }
        if ($AuthorizedKeys) {
            $AuthorizedKeys
        }
    )
    Set-Content -Path $Keys -Value ($Lines -join "`n")
    chmod 600 $Keys

    try {
        $Fingerprints = ssh-keygen -lf $Keys 2>$null
    } catch {
        Write-Host '::error::No usable SSH public keys. Add one at https://github.com/settings/keys or set the SSH_AUTHORIZED_KEYS repository variable.'
        exit 1
    }
    Write-Host 'Authorized keys:'
    Write-Host ($Fingerprints -join "`n")

    $HostKey = Join-Path $StateDir 'ssh_host_ed25519_key'
    if (-not (Test-Path -Path $HostKey)) {
        ssh-keygen -q -t ed25519 -N '' -C macos-vm -f $HostKey
    }
    $HostFingerprint = (-split (ssh-keygen -lf "$HostKey.pub"))[1]

    # UsePAM runs the account and session stacks macOS expects (pam_launchd puts
    # the login in the user's launchd domain, which keychain and launchctl need).
    # With password and keyboard-interactive auth off, PAM never asks for a password.
    $Config = Join-Path $StateDir 'sshd_config'
    Set-Content -Path $Config -Value @"
Port $Port
ListenAddress 127.0.0.1
HostKey $HostKey
PidFile $SshdPidFile
AuthorizedKeysFile $Keys
AllowUsers $User
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
ClientAliveInterval 30
Subsystem sftp internal-sftp
"@

    sudo /usr/sbin/sshd -t -f $Config
    sudo /usr/sbin/sshd -f $Config -E $SshdLog
    # sshd goes to the background before it binds the port, so its exit status
    # says nothing about that; it writes the pid file once it is listening.
    for ($I = 0; $I -lt 100 -and -not (Test-Path -Path $SshdPidFile); $I++) {
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -Path $SshdPidFile)) {
        Write-Host "::error::sshd did not start listening on 127.0.0.1:$Port"
        Get-Content -Tail 50 -Path $SshdLog -ErrorAction SilentlyContinue
        exit 1
    }
    $SshdPid = Get-Content -Path $SshdPidFile
    Write-Host "sshd listening on 127.0.0.1:$Port (host key $HostFingerprint)"

    # Not Start-Process: it can't send both output streams to one file, and on
    # macOS and Linux its redirection is relayed through this pwsh process, so
    # the log would stop when the script exits. sh starts cloudflared detached.
    $TunnelPid = sh -c 'nohup cloudflared tunnel --no-autoupdate --url "$1" > "$2" 2>&1 & echo $!' sh "ssh://127.0.0.1:$Port" $TunnelLog

    # cloudflared prints the hostname first and can take a few more seconds to
    # register a connection with Cloudflare's edge.
    $TunnelHost = $null
    $Registered = $false
    for ($I = 0; $I -lt 60; $I++) {
        if (-not (Test-Running $TunnelPid)) {
            Write-Host '::error::cloudflared exited before the tunnel was ready'
            Get-Content -Path $TunnelLog
            exit 1
        }
        $Text = "$(Get-Content -Raw -Path $TunnelLog -ErrorAction SilentlyContinue)"
        if (-not $TunnelHost) {
            $TunnelHost = [regex]::Matches($Text, 'https://([a-z0-9-]+\.trycloudflare\.com)') |
                ForEach-Object { $_.Groups[1].Value } |
                Where-Object { $_ -ne 'api.trycloudflare.com' } |
                Select-Object -First 1
        }
        $Registered = $Text.Contains('Registered tunnel connection')
        if ($TunnelHost -and $Registered) {
            break
        }
        Start-Sleep -Seconds 1
    }
    if (-not $TunnelHost) {
        Write-Host '::error::cloudflared did not report a tunnel hostname'
        Get-Content -Path $TunnelLog
        exit 1
    }
    if (-not $Registered) {
        Write-Host '::warning::cloudflared has not registered a connection yet; the first connect attempt may fail'
    }
    Write-Host "Tunnel: $TunnelHost -> 127.0.0.1:$Port"

    $EndSessionSource = Join-Path $StateDir 'end-session'
    Set-Content -Path $EndSessionSource -Value @"
#!/bin/bash
# Ends the SSH session started by vasama/macos.
touch '$StopFile'
echo 'Ending the session. This connection closes within a few seconds.'
"@
    sudo mkdir -p $BinDir
    sudo install -m 755 $EndSessionSource (Join-Path $BinDir 'end-session')

    $Watched = @(
        @{ Name = 'sshd'; Id = $SshdPid; Log = $SshdLog }
        @{ Name = 'cloudflared'; Id = $TunnelPid; Log = $TunnelLog }
    )
    $End = (Get-Date).AddMinutes($Timeout)
    $NextInfo = Get-Date
    while ((Get-Date) -lt $End) {
        if (Test-Path -Path $StopFile) {
            Write-Host 'Session ended with end-session.'
            exit 0
        }
        foreach ($Process in $Watched) {
            if (-not (Test-Running $Process.Id)) {
                Write-Host "::error::$($Process.Name) exited; the session is no longer reachable."
                Get-Content -Tail 50 -Path $Process.Log -ErrorAction SilentlyContinue
                exit 1
            }
        }
        if ((Get-Date) -ge $NextInfo) {
            Write-ConnectionInfo
            $NextInfo = (Get-Date).AddMinutes(5)
        }
        Start-Sleep -Seconds 5
    }
    Write-Host "Timeout of $Timeout min reached."
} finally {
    Revoke-Access
}
