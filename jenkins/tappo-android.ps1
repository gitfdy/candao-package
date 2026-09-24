# Java tools write normal status messages to stderr on Windows PowerShell 5.1.
function Invoke-SigningTool([string]$Command, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $output = & $Command @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Signing tool failed: $(Split-Path $Command -Leaf), exit $LASTEXITCODE; check keystore, alias and passwords" }
    return @($output | ForEach-Object { $_.ToString() })
}

function ConvertTo-JavaProperty([string]$Value) {
    $result = [Text.StringBuilder]::new()
    foreach ($c in $Value.ToCharArray()) {
        # Escaping every character also preserves Unicode passwords and leading spaces.
        [void]$result.Append(('\u{0:x4}' -f [int]$c))
    }
    return $result.ToString()
}

# Build only; distribution remains controlled by the Pipeline switches.
function Get-TappoBuildArguments([string]$Project, [string]$Environment, [string]$Format, [string]$VersionCode) {
    $allowed = @{ tappo = @('qc', 'beta', 'gray', 'release'); tappo_phone = @('qc', 'prod') }
    if (!$allowed.ContainsKey($Project) -or $Environment -notin $allowed[$Project]) { throw 'Unsupported project/environment' }
    if ($Format -notin @('apk', 'aab')) { throw 'Choose apk or aab' }
    if ($VersionCode -and ($VersionCode -notmatch '^[1-9][0-9]{0,9}$' -or [long]$VersionCode -gt 2100000000)) { throw 'Invalid Android version code' }
    $target = if ($Format -eq 'aab') { 'appbundle' } else { 'apk' }
    $result = @('build', $target, '--release', '--dart-define=enable_dev_tools=false')
    if ($Project -eq 'tappo') {
        $result += @("--dart-define=build_env=$Environment", '--dart-define=test_production=false')
        if ($Format -eq 'apk') { $result += '--dart-define=channel=office' }
    } else {
        $channel = if ($Format -eq 'apk') { 'office' } else { 'store' }
        $result += @("--dart-define=flavor=$Environment", "--dart-define=update_channel=$channel")
    }
    $office = if ($Format -eq 'apk') { 'true' } else { 'false' }
    $result += "--android-project-arg=officeChannel=$office"
    if ($VersionCode) { $result += "--build-number=$VersionCode" }
    return $result
}

function Get-CertificateSha256([string[]]$PemLines) {
    $pem = $PemLines -join "`n"
    $match = [regex]::Match($pem, '(?s)-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----')
    if (!$match.Success) { throw 'No signing certificate found' }
    $bytes = [Convert]::FromBase64String(($match.Groups[1].Value -replace '\s', ''))
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-', '') }
    finally { $hash.Dispose() }
}

function Invoke-TappoAndroidBuild {
    $ErrorActionPreference = 'Stop'
    $buildArgs = Get-TappoBuildArguments $env:PROJECT $env:ENVIRONMENT $env:PACKAGE_FORMAT $env:VERSION_CODE
    if ($env:PROJECT -eq 'tappo_phone' -and $env:PACKAGE_FORMAT -eq 'aab' -and !$env:SIGNING_KEY) { throw 'Tappo Phone AAB requires the existing Google Play upload key' }
    $root = (Resolve-Path source).Path
    $app = if ($env:PROJECT -eq 'tappo_phone') { Join-Path $root 'apps/mobile' } else { $root }
    $version = (Get-Content "$root/.fvmrc" -Raw | ConvertFrom-Json).flutter
    if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Commit a stable Flutter version in .fvmrc' }
    $sdk = "D:\work\candao-package\.jenkins-sdk\flutter-$version"
    $lockPath = "D:\work\candao-package\.jenkins-sdk\flutter-$version.lock"
    if (!(Test-Path "$sdk/bin/flutter.bat")) {
        $sdk = 'D:\work\self-checkout\.fvm\flutter_sdk'
        $lockPath = 'D:\work\candao-package\.jenkins-sdk\self-checkout-sdk.lock'
    }
    if (!(Test-Path "$sdk/bin/flutter.bat")) { throw "Install Flutter $version on this node" }
    $actual = & git -C $sdk describe --tags --exact-match
    if ($LASTEXITCODE -ne 0 -or "$actual".Trim() -ne $version) { throw "Flutter SDK must match $version" }
    $flutter = "$sdk/bin/flutter.bat"
    $env:ANDROID_HOME = 'C:\Users\Administrator\AppData\Local\Android\Sdk'
    $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
    if (!(Test-Path "$env:ANDROID_HOME/platform-tools/adb.exe")) { throw 'Android SDK missing' }
    $keytool = Join-Path $env:JAVA_HOME 'bin/keytool.exe'
    $jarsigner = Join-Path $env:JAVA_HOME 'bin/jarsigner.exe'
    if (!(Test-Path $keytool) -or !(Test-Path $jarsigner)) { throw 'JAVA_HOME must point to a JDK with keytool and jarsigner' }
    $buildTools = Get-ChildItem "$env:ANDROID_HOME/build-tools" -Directory | Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    $apksigner = Join-Path $buildTools.FullName 'apksigner.bat'
    if (!(Test-Path $apksigner)) { throw 'Android build-tools/apksigner missing' }
    $keyProperties = Join-Path $app 'android/key.properties'
    $sdkLock = $null
    $text = $null
    try {
        while ($null -eq $sdkLock) {
            try { $sdkLock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
            catch [IO.IOException] { Start-Sleep -Seconds 5 }
        }
        if ($env:SIGNING_KEY) {
            foreach ($name in @('TAPPO_PHONE_KEYSTORE_PATH', 'TAPPO_PHONE_STORE_PASSWORD', 'TAPPO_PHONE_KEY_PASSWORD', 'TAPPO_PHONE_KEY_ALIAS', 'TAPPO_PHONE_UPLOAD_SHA256')) {
                if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) { throw "Missing signing credential: $name" }
            }
            $expected = ($env:TAPPO_PHONE_UPLOAD_SHA256 -replace '[:\s]', '').ToUpperInvariant()
            if ($expected -notmatch '^[0-9A-F]{64}$') { throw 'Upload certificate SHA256 must contain 64 hex digits' }
            $cert = Invoke-SigningTool $keytool @('-exportcert', '-rfc', '-keystore', $env:TAPPO_PHONE_KEYSTORE_PATH, '-storepass:env', 'TAPPO_PHONE_STORE_PASSWORD', '-alias', $env:TAPPO_PHONE_KEY_ALIAS)
            if ((Get-CertificateSha256 $cert) -ne $expected) { throw 'Keystore does not match the Google Play upload certificate' }
        } else {
            # Persistent internal-only Android debug key; never a replacement for a Play upload key.
            $keystore = Join-Path $env:JENKINS_HOME "ci-signing/$env:PROJECT/debug.keystore"
            New-Item -ItemType Directory -Force -Path (Split-Path $keystore) | Out-Null
            if (!(Test-Path $keystore)) {
                Invoke-SigningTool $keytool @('-genkeypair', '-keystore', $keystore, '-storepass', 'android', '-keypass', 'android', '-alias', 'androiddebugkey', '-keyalg', 'RSA', '-keysize', '2048', '-validity', '10000', '-dname', 'CN=Android Debug,O=Android,C=US') | Out-Null
            }
            $cert = Invoke-SigningTool $keytool @('-exportcert', '-rfc', '-keystore', $keystore, '-storepass', 'android', '-alias', 'androiddebugkey')
            $expected = Get-CertificateSha256 $cert
            $env:TAPPO_PHONE_KEYSTORE_PATH = $keystore
            $env:TAPPO_PHONE_STORE_PASSWORD = 'android'
            $env:TAPPO_PHONE_KEY_PASSWORD = 'android'
            $env:TAPPO_PHONE_KEY_ALIAS = 'androiddebugkey'
            Write-Output 'Internal test certificate: not for Google Play or replacing differently signed installations.'
        }
        if ($env:PROJECT -eq 'tappo') {
            if (Test-Path $keyProperties) { throw 'Unexpected committed key.properties; refuse to overwrite signing configuration' }
            $text = @(
                'storeFile=' + (ConvertTo-JavaProperty $env:TAPPO_PHONE_KEYSTORE_PATH)
                'storePassword=' + (ConvertTo-JavaProperty $env:TAPPO_PHONE_STORE_PASSWORD)
                'keyAlias=' + (ConvertTo-JavaProperty $env:TAPPO_PHONE_KEY_ALIAS)
                'keyPassword=' + (ConvertTo-JavaProperty $env:TAPPO_PHONE_KEY_PASSWORD)
            ) -join "`n"
            [IO.File]::WriteAllText($keyProperties, $text, [Text.UTF8Encoding]::new($false))
        }
        Push-Location $app
        try {
            $ErrorActionPreference = 'Continue'
            & $flutter pub get
            $ErrorActionPreference = 'Stop'
            if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }
            $ErrorActionPreference = 'Continue'
            & $flutter @buildArgs
            $ErrorActionPreference = 'Stop'
            if ($LASTEXITCODE -ne 0) { throw 'Android build failed' }
        } finally { Pop-Location }
        $output = if ($env:PACKAGE_FORMAT -eq 'apk') { "$app/build/app/outputs/flutter-apk/app-release.apk" } else { "$app/build/app/outputs/bundle/release/app-release.aab" }
        if (!(Test-Path $output) -or (Get-Item $output).Length -le 0) { throw 'Expected Android artifact missing or empty' }
        if ($env:PACKAGE_FORMAT -eq 'apk') {
            $verification = Invoke-SigningTool $apksigner @('verify', '--print-certs', $output)
            $match = [regex]::Match(($verification -join "`n"), 'certificate SHA-256 digest:\s*([0-9a-fA-F]{64})')
            if (!$match.Success -or $match.Groups[1].Value.ToUpperInvariant() -ne $expected) { throw 'APK signing certificate mismatch' }
        } else {
            Invoke-SigningTool $jarsigner @('-verify', $output) | Out-Null
            $cert = Invoke-SigningTool $keytool @('-printcert', '-rfc', '-jarfile', $output)
            if ((Get-CertificateSha256 $cert) -ne $expected) { throw 'AAB signing certificate mismatch' }
        }
        $manifest = Get-Content "$app/pubspec.yaml" -Raw
        $appVersion = [regex]::Match($manifest, '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)').Groups[1].Value
        if (!$appVersion) { throw 'Cannot read application version' }
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $signingLabel = if ($env:SIGNING_KEY) { 'signed' } else { 'internal' }
        $name = "${env:PROJECT}_android_${stamp}_v${appVersion}_${env:ENVIRONMENT}_${signingLabel}.${env:PACKAGE_FORMAT}"
        New-Item -ItemType Directory -Force -Path artifacts | Out-Null
        Copy-Item -LiteralPath $output -Destination "artifacts/$name"
        Get-FileHash "artifacts/$name" -Algorithm SHA256 | Format-List
        "Signing certificate SHA256: $expected" | Set-Content 'artifacts/signing-certificate.txt'
    } finally {
        if ($env:PROJECT -eq 'tappo' -and (Test-Path $keyProperties) -and $text) { Remove-Item -LiteralPath $keyProperties -Force }
        if ($sdkLock) { $sdkLock.Dispose() }
    }
}
