# Run from an elevated Windows PowerShell. No passwords are stored or changed.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Use a client IP or VPN subnet when access is needed beyond the local subnet.
    [ValidateNotNullOrEmpty()]
    [string[]]$AllowedRemoteAddress = @('LocalSubnet')
)

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
if ($PSCmdlet.ShouldProcess($ruleName, "Allow inbound TCP 22 from $($AllowedRemoteAddress -join ', ')")) {
    $rule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
    if ($rule) {
        $rule | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress $AllowedRemoteAddress
        $rule | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -Protocol TCP -LocalPort 22 -RemotePort Any
        $rule | Set-NetFirewallRule -DisplayName 'OpenSSH Server (scoped access)' -Enabled True -Direction Inbound -Action Allow -Profile Any
    } else {
        New-NetFirewallRule -Name $ruleName -DisplayName 'OpenSSH Server (scoped access)' `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow `
            -LocalPort 22 -RemoteAddress $AllowedRemoteAddress -Profile Any | Out-Null
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
    Write-Output "Standard OpenSSH firewall rule allows: $($AllowedRemoteAddress -join ', '). Custom firewall rules are unchanged."
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

Write-Output 'Windows IPv4 addresses (use an address reachable from your Mac):'
$addresses = @(Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred |
    Where-Object { $_.IPAddress -notmatch '^(127[.]|169[.]254[.])' })
foreach ($address in $addresses) {
    Write-Output "$($address.InterfaceAlias): $($address.IPAddress)/$($address.PrefixLength)"
    Write-Output ('  ssh -l "' + $identity.Name + '" ' + $address.IPAddress)
}
if (!$addresses.Count) { Write-Warning 'No usable IPv4 address was found.' }
Write-Output 'No VPN or router port forwarding was configured. UU desktop access does not provide an SSH network route.'
Write-Output 'Outside the company LAN, obtain a VPN or another reachable network route before connecting.'
Write-Output 'For a routed client/VPN, rerun with -AllowedRemoteAddress set to its actual client IP or subnet.'
