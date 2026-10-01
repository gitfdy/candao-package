$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/tappo-android.ps1"
function Assert($Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Reject([scriptblock]$Action) { $failed = $false; try { & $Action } catch { $failed = $true }; Assert $failed 'Expected rejection' }
foreach ($project in @('tappo', 'tappo_phone')) {
    $environments = if ($project -eq 'tappo') { @('qc', 'beta', 'gray', 'release') } else { @('qc', 'prod') }
    foreach ($environment in $environments) {
        foreach ($format in @('apk', 'aab')) {
            $arguments = Get-TappoBuildArguments $project $environment $format '123'
            Assert ('--release' -in $arguments) 'All environments must support release compilation'
            Assert ('--build-number=123' -in $arguments) 'versionCode override missing'
            if ($format -eq 'aab') {
                Assert ($arguments[1] -eq 'appbundle') 'AAB must call appbundle'
                Assert ('--android-project-arg=officeChannel=false' -in $arguments) 'Store package must remove installer permission'
                Assert (!($arguments -match '=office$')) 'Store package cannot use office channel'
            } else {
                Assert ($arguments[1] -eq 'apk') 'APK command incorrect'
                Assert ('--android-project-arg=officeChannel=true' -in $arguments) 'APK office permission missing'
            }
            $define = if ($project -eq 'tappo') { "--dart-define=build_env=$environment" } else { "--dart-define=flavor=$environment" }
            Assert ($define -in $arguments) 'Environment must be explicit'
        }
    }
}
Reject { Get-TappoBuildArguments tappo_phone release apk '' }
Reject { Get-TappoBuildArguments tappo qc zip '' }
Reject { Get-TappoBuildArguments tappo qc apk '-1' }
Reject { Get-TappoBuildArguments tappo qc apk '2100000001' }
Reject { Get-CertificateSha256 @('unsigned') }
Assert ((ConvertTo-JavaProperty (" a\" + [char]0x4e2d + "`n")) -eq '\u0020\u0061\u005c\u4e2d\u000a') 'Java properties must preserve passwords exactly'
$env:PROJECT = 'tappo_phone'; $env:PACKAGE_FORMAT = 'aab'; $env:ENVIRONMENT = 'prod'; $env:SIGNING_KEY = ''; $env:VERSION_CODE = ''
Reject { Invoke-TappoAndroidBuild }
$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/tappo-android.ps1", [ref]$tokens, [ref]$errors) | Out-Null
Assert (!$errors) "Parser errors: $errors"
Write-Output 'PASS: environment/format matrix, Play channel, versionCode, signing requirement and password escaping'
if ($env:JAVA_HOME) {
    $toolName = if ($env:OS -eq 'Windows_NT') { 'keytool.exe' } else { 'keytool' }
    $keytool = Join-Path $env:JAVA_HOME "bin/$toolName"
    $tempKey = Join-Path ([IO.Path]::GetTempPath()) (([guid]::NewGuid().ToString()) + '.jks')
    try {
        Invoke-SigningTool $keytool @('-genkeypair', '-keystore', $tempKey, '-storepass', 'android', '-keypass', 'android', '-alias', 'test', '-keyalg', 'RSA', '-keysize', '2048', '-validity', '1', '-dname', 'CN=CI Test') | Out-Null
        $cert = Invoke-SigningTool $keytool @('-exportcert', '-rfc', '-keystore', $tempKey, '-storepass', 'android', '-alias', 'test')
        $listing = Invoke-SigningTool $keytool @('-J-Duser.language=en', '-list', '-v', '-keystore', $tempKey, '-storepass', 'android', '-alias', 'test')
        $fingerprint = [regex]::Match(($listing -join "`n"), 'SHA256:\s*([0-9A-Fa-f:]+)').Groups[1].Value.Replace(':', '').ToUpperInvariant()
        Assert ((Get-CertificateSha256 $cert) -eq $fingerprint) 'Certificate digest must match keytool'
        Reject { Invoke-SigningTool $keytool @('-list', '-keystore', $tempKey, '-storepass', 'incorrect') }
        Write-Output 'PASS: real keystore generation, certificate fingerprint and bad-password rejection'
    } finally { if (Test-Path $tempKey) { Remove-Item $tempKey -Force } }
}

$legacyGradle = @'
android {
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}
'@
$prepared = ConvertTo-TappoPhoneCiSigning $legacyGradle
Assert ($prepared.Contains('signingConfig = signingConfigs.getByName("jenkinsRelease")')) 'Legacy release must use the CI signer'
Assert (!$prepared.Contains('getByName("debug")')) 'Legacy debug signer must be replaced'
foreach ($name in @('KEYSTORE_PATH', 'STORE_PASSWORD', 'KEY_ALIAS', 'KEY_PASSWORD')) {
    Assert ($prepared.Contains('System.getenv("TAPPO_PHONE_' + $name + '")')) 'CI signing field missing'
}
Assert ((ConvertTo-TappoPhoneCiSigning $prepared) -ceq $prepared) 'Existing environment-based signing must remain unchanged'
Reject { ConvertTo-TappoPhoneCiSigning ($legacyGradle.Replace('getByName("debug")', 'getByName("custom")')) }
Reject { ConvertTo-TappoPhoneCiSigning ($legacyGradle + '
signingConfigs { create("custom") }') }
Write-Output 'PASS: legacy Phone signing adaptation, environment-based signing preservation and unknown-config rejection'
Assert ((Get-TappoArtifactVersion 'version: 2.4.10+123' '') -eq '2.4.10') 'AAB declared version must remain unchanged'
$badging = "package: name='com.example.mobile' versionCode='1' versionName='1.0' platformBuildVersionName='16'"
Assert ((Get-TappoArtifactVersion 'name: mobile' $badging) -eq '1.0') 'Missing version must use actual APK metadata'
Assert ((Get-TappoArtifactVersion 'version: 2.4.10+123' $badging) -eq '1.0') 'APK metadata must reflect actual Gradle overrides'
Reject { Get-TappoArtifactVersion 'name: mobile' '' }
Reject { Get-TappoArtifactVersion 'name: mobile' ($badging.Replace("versionName='1.0'", "versionName='../invalid'")) }
Write-Output 'PASS: declared AAB and actual APK versions, missing and unsafe version rejection'
