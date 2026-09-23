# Run from an elevated Windows PowerShell. No passwords are stored or changed.
[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open Windows PowerShell as Administrator, then run this script again.'
}

$capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
if (!$capability -or $capability.State -ne 'Installed') {
    if ($PSCmdlet.ShouldProcess('Windows', 'Install OpenSSH Server')) {
        $result = Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
        if ($result.RestartNeeded) {
            throw 'OpenSSH installation requires a Windows restart. Restart, then run this script again.'
        }
    }
}

# Installation can create a broad default allow rule. Restrict it before starting SSH.
$ruleName = 'OpenSSH-Server-In-TCP'
$tailscaleRange = '100.64.0.0/10'
if ($PSCmdlet.ShouldProcess($ruleName, "Allow inbound TCP 22 only from $tailscaleRange")) {
    $rule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
    if ($rule) {
        $rule | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress $tailscaleRange
        $rule | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -Protocol TCP -LocalPort 22 -RemotePort Any
        $rule | Set-NetFirewallRule -Enabled True -Direction Inbound -Action Allow -Profile Any
    } else {
        New-NetFirewallRule -Name $ruleName -DisplayName 'OpenSSH Server (Tailscale)' `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow `
            -LocalPort 22 -RemoteAddress $tailscaleRange -Profile Any | Out-Null
    }
}

if ($PSCmdlet.ShouldProcess('sshd', 'Enable automatic startup and start SSH')) {
    Set-Service -Name sshd -StartupType Automatic
    Start-Service -Name sshd
    $listening = $null
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $listening = Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction SilentlyContinue
        if ($listening) { break }
        Start-Sleep -Seconds 1
    }
    if (!$listening) { throw 'sshd started but TCP 22 is not listening. Check the existing sshd_config.' }
    Write-Output 'SSH is running and TCP 22 is listening.'
    Write-Output 'The standard OpenSSH firewall rule allows Tailscale addresses only; custom firewall rules are unchanged.'
}

Write-Output "Windows login identity: $($identity.Name)"
Write-Output 'Use the Windows account password, not the Windows Hello PIN or Jenkins password.'
$keygen = Join-Path $env:WINDIR 'System32/OpenSSH/ssh-keygen.exe'
$hostKey = Join-Path $env:ProgramData 'ssh/ssh_host_ed25519_key.pub'
if ((Test-Path -LiteralPath $keygen) -and (Test-Path -LiteralPath $hostKey)) {
    Write-Output 'Verify this host fingerprint on your Mac before accepting the first SSH connection:'
    & $keygen -lf $hostKey
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read the SSH host fingerprint' }
}

$tailscale = Join-Path $env:ProgramFiles 'Tailscale/tailscale.exe'
if (!(Test-Path -LiteralPath $tailscale)) {
    Write-Warning 'Tailscale was not found. Install/sign in to Tailscale on both devices before connecting.'
    return
}
$statusJson = & $tailscale status --json
if ($LASTEXITCODE -ne 0) { throw 'Cannot read Tailscale status. Open Tailscale and check its connection.' }
$status = $statusJson | ConvertFrom-Json
Write-Output "Tailscale state: $($status.BackendState)"
Write-Output "Tailscale network: $($status.CurrentTailnet.Name)"
$ip = @($status.TailscaleIPs | Where-Object { $_ -match '^100[.]' }) | Select-Object -First 1
if ($status.BackendState -ne 'Running' -or !$ip) {
    Write-Warning 'Tailscale is not connected. SSH setup alone cannot make the two devices reachable.'
    return
}
Write-Output "Windows Tailscale IP: $ip"
Write-Output ('Mac command: ssh -l "' + $identity.Name + '" ' + $ip)
Write-Output "Jenkins address: http://${ip}:8080/ (availability not tested by this script)"
Write-Output 'Both devices must join the same Tailscale network, or have an authorized device share/access policy.'
