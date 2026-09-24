# Offline checks. HTTP is mocked; no Jenkins, DUFS or DingTalk writes.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"
. "$PSScriptRoot/prepare-toa-build.ps1"
function Assert($condition, [string]$message) { if (!$condition) { throw $message } }
function Expect-Failure([scriptblock]$action) {
    $failed = $false
    try { & $action } catch { $failed = $true }
    Assert $failed 'Expected failure'
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ("candao test " + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $temp | Out-Null
Push-Location $temp
try {
    New-Item -ItemType Directory -Path 'adapter/scripts', 'adapter/lib' | Out-Null
    $fixture = @'
if "%BUILD_TYPE%"=="release" (
)
if "%BUILD_TYPE%"=="pre-prod" (
)
if "%BUILD_TYPE%"=="release" goto :build_shorebird_windows
:build_flutter_windows
call %FLUTTER_CMD% build windows --%BUILD_MODE% %BUILD_PARAMS%
'@
    Set-Content adapter/scripts/build_windows.bat $fixture
    Set-Content adapter/lib/main.dart "const String.fromEnvironment('pre_production');"
    Prepare-ToaBuild "$temp/adapter" release
    $adapted = Get-Content adapter/scripts/build_windows.bat -Raw
    Assert (!$adapted.Contains('goto :build_shorebird_windows')) 'Production must not route to Shorebird'
    Assert ($adapted.Contains('if errorlevel 1 exit /b 1')) 'Flutter errors must stop packaging'
    Prepare-ToaBuild "$temp/adapter" pre-prod
    Set-Content adapter/lib/main.dart '// No pre-production configuration'
    Expect-Failure { Prepare-ToaBuild "$temp/adapter" pre-prod }
    Expect-Failure { Prepare-ToaBuild "$temp/adapter" unknown }
    Set-Content adapter/scripts/build_windows.bat ($fixture.Replace('if "%BUILD_TYPE%"=="release" goto :build_shorebird_windows', 'call shorebird release windows'))
    Expect-Failure { Prepare-ToaBuild "$temp/adapter" release }
    $incidentFixture = $fixture + @'

if /i "%BUILD_TYPE%"=="release" goto :require_incident_config
:require_incident_config
set "BUILD_PARAMS=!BUILD_PARAMS! --dart-define=TOA_INCIDENT_UPLOAD_ENABLED=true"
:incident_config_ready
set "BUILD_PARAMS=!BUILD_PARAMS! --dart-define=TOA_INCIDENT_BUILD_MANIFEST_B64=manifest"
'@
    $savedIncidentUrl = $env:TOA_INCIDENT_API_BASE_URL
    try {
        $env:TOA_INCIDENT_API_BASE_URL = ''
        Set-Content adapter/scripts/build_windows.bat $incidentFixture
        Prepare-ToaBuild "$temp/adapter" release false
        $adapted = Get-Content adapter/scripts/build_windows.bat -Raw
        Assert ($adapted -match '(?s):require_incident_config\r?\nset "BUILD_PARAMS=.*?TOA_INCIDENT_UPLOAD_ENABLED=false"\r?\ngoto :incident_config_ready') 'Disabled Incident must skip the address requirement'
        Assert ($adapted.Contains('TOA_INCIDENT_BUILD_MANIFEST_B64=manifest')) 'Keep build manifest when upload is disabled'
        foreach ($url in @('', 'http://incident.example.com', 'https://user@incident.example.com', 'https://incident.example.com?q=1', 'https://incident.example.com/#fragment')) {
            $env:TOA_INCIDENT_API_BASE_URL = $url
            Set-Content adapter/scripts/build_windows.bat $incidentFixture
            Expect-Failure { Prepare-ToaBuild "$temp/adapter" release true }
        }
        $env:TOA_INCIDENT_API_BASE_URL = 'https://incident.example.com'
        Set-Content adapter/scripts/build_windows.bat $incidentFixture
        Prepare-ToaBuild "$temp/adapter" release true
        Assert (!(Get-Content adapter/scripts/build_windows.bat -Raw).Contains('TOA_INCIDENT_UPLOAD_ENABLED=false')) 'Enabled Incident must keep upstream validation'
        Expect-Failure { Prepare-ToaBuild "$temp/adapter" release invalid }
        Set-Content adapter/scripts/build_windows.bat $fixture
        Expect-Failure { Prepare-ToaBuild "$temp/adapter" release true }
    } finally { $env:TOA_INCIDENT_API_BASE_URL = $savedIncidentUrl }
    & "$PSScriptRoot/sync-jobs.ps1" -OutputDirectory "$temp/xml"
    foreach ($file in Get-ChildItem "$temp/xml/*.xml") {
        [xml]$xml = Get-Content $file -Raw -Encoding UTF8
        $parameters = $xml.SelectNodes('//parameterDefinitions/*')
        foreach ($name in @('BRANCH', 'UPLOAD_DUFS', 'SEND_DINGTALK')) {
            Assert ($name -in $parameters.name) "Missing parameter: $name"
        }
        Assert ($xml.SelectSingleNode("//parameterDefinitions/*[name='UPLOAD_DUFS']/defaultValue").InnerText -eq 'false') 'Upload must default off'
        Assert ($xml.SelectSingleNode("//parameterDefinitions/*[name='SEND_DINGTALK']/defaultValue").InnerText -eq 'false') 'Notification must default off'
        foreach ($name in @('DUFS_CREDENTIALS_ID', 'DINGTALK_CREDENTIALS_ID')) {
            Assert ($name -notin $parameters.name) 'Credential IDs must not be build parameters'
        }
        $definition = $xml.SelectSingleNode('//definition')
        Assert ($definition.GetAttribute('class') -eq 'org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition') 'Pipeline must load from Git SCM'
        Assert ($definition.scriptPath -eq "jenkins/$($file.BaseName.Replace('TAPPO-PHONE-Android', 'tappo-phone-android').Replace('TAPPO-Android', 'tappo-android').Replace('TOA-KIOSK-WINDOWS', 'kiosk-windows').Replace('HPOS-Android-Package', 'hpos').Replace('Candao-Windows-Package', 'windows').Replace('TOA-POS-Windows', 'toa-windows').Replace('Candao-Android-Package', 'android')).Jenkinsfile") 'Wrong Jenkinsfile path'
        Assert ($definition.scm.userRemoteConfigs.'hudson.plugins.git.UserRemoteConfig'.url -eq ((git -C $PSScriptRoot remote get-url origin).Trim() -replace '^(https?://)[^/]*@', '$1')) 'Wrong Git repository'
        $pipeline = Get-Content (Join-Path $PSScriptRoot $definition.scriptPath.Replace('jenkins/', '')) -Raw
        Assert (!$pipeline.Contains('# @include')) 'Unexpanded helper'
        if ($pipeline.Contains('activeChoice(')) {
            Assert ($pipeline.Contains('def credentialScope = Jenkins.get()')) 'Global Git credentials must not depend on job names'
            Assert (!$pipeline.Contains('getItemByFullName(')) 'Branch lookup must not hard-code job names'
        }
        foreach ($match in [regex]::Matches($pipeline, "(?s)powershell '''(.*?)'''")) {
            $code = $match.Groups[1].Value.Replace('\\', '\').Replace("\'", "'")
            $errors = $null; $tokens = $null
            [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$errors) | Out-Null
            Assert (!$errors) "PowerShell parse error: $errors"
        }
        Assert ($pipeline.IndexOf("stage('Verify and archive')") -lt $pipeline.IndexOf("stage('Upload DUFS')")) 'Archive before upload'
        Assert ($pipeline.Contains('when { expression { params.UPLOAD_DUFS } }')) 'Missing upload guard'
        Assert ($pipeline.Contains('when { expression { params.SEND_DINGTALK } }')) 'Missing notification guard'
        $notification = $pipeline.Substring($pipeline.IndexOf("stage('Notify DingTalk')"))
        Assert ($notification -match "(?s)catchError\(buildResult: 'SUCCESS', stageResult: 'UNSTABLE', catchInterruptions: false,.*?\{\s+withCredentials") 'Notification failures must not fail the build; manual aborts must propagate'
        Assert ($pipeline.Contains("DUFS_CREDENTIALS_ID = 'dufs'")) 'Missing fixed DUFS credential'
        Assert ($pipeline.Contains("DINGTALK_CREDENTIALS_ID = 'dingtalk-webhook'")) 'Missing fixed DingTalk credential'
        Assert ($pipeline.Contains('credentialsId: env.DUFS_CREDENTIALS_ID')) 'DUFS binding must use configured credential'
        Assert ($pipeline.Contains('credentialsId: env.DINGTALK_CREDENTIALS_ID')) 'DingTalk binding must use configured credential'
    }
    foreach ($newJob in @('TAPPO-Android', 'TAPPO-PHONE-Android')) {
        [xml]$mobile = Get-Content "$temp/xml/$newJob.xml" -Raw -Encoding UTF8
        Assert ($mobile.SelectSingleNode("//parameterDefinitions/*[name='PACKAGE_FORMAT']/choices/a/string[1]").InnerText -eq 'apk') 'APK must be the default'
        Assert ($mobile.SelectSingleNode("//parameterDefinitions/*[name='SIGNING_KEY']/credentialType").InnerText -eq 'org.jenkinsci.plugins.plaincredentials.impl.FileCredentialsImpl') 'Signing dropdown must filter to Secret file credentials'
        Assert ($mobile.SelectSingleNode("//parameterDefinitions/*[name='SIGNING_KEY']").LocalName -eq 'com.cloudbees.plugins.credentials.CredentialsParameterDefinition') 'Signing key must use the credentials store'
    }
    [xml]$hpos = Get-Content "$temp/xml/HPOS-Android-Package.xml" -Raw -Encoding UTF8
    Assert ((Get-Content "$PSScriptRoot/kiosk-windows.Jenkinsfile" -Raw).Contains("name: 'refs/heads/v3.8.1-TA'")) 'Kiosk requires the Octopus TOA-compatible interfaces'
    [xml]$kiosk = Get-Content "$temp/xml/TOA-KIOSK-WINDOWS.xml" -Raw -Encoding UTF8
    Assert ($kiosk.SelectSingleNode('//definition/scriptPath').InnerText -eq 'jenkins/kiosk-windows.Jenkinsfile') 'Kiosk must use Windows pipeline'
    Assert ($null -eq $kiosk.SelectSingleNode("//parameterDefinitions/*[name='DUFS_URL' or name='PROJECT']")) 'Kiosk infrastructure fields must be hidden'
    Assert ($kiosk.SelectSingleNode("//parameterDefinitions/*[name='BRANCH']").LocalName -eq 'org.biouno.unochoice.ChoiceParameter') 'Kiosk branches must be dynamic'
    Assert ((($kiosk.SelectNodes("//parameterDefinitions/*[name='PRODUCT']/choices/a/string") | ForEach-Object InnerText) -join ',') -eq 'kiosk,self_checkout') 'Kiosk product choices mismatch'
    Assert ((($kiosk.SelectNodes("//parameterDefinitions/*[name='ENVIRONMENT']/choices/a/string") | ForEach-Object InnerText) -join ',') -eq 'staging,test-prod,release,debug') 'Kiosk environments mismatch'
    Assert ($null -eq $hpos.SelectSingleNode("//parameterDefinitions/*[name='DUFS_URL' or name='REPOSITORY_URL']")) 'HPOS infrastructure fields must be hidden'
    Assert ($hpos.SelectSingleNode("//parameterDefinitions/*[name='BRANCH']").LocalName -eq 'org.biouno.unochoice.ChoiceParameter') 'HPOS branches must be dynamic'
    [xml]$toa = Get-Content "$temp/xml/TOA-POS-Windows.xml" -Raw -Encoding UTF8
    Assert ($toa.SelectSingleNode("//parameterDefinitions/*[name='BRANCH']").LocalName -eq 'org.biouno.unochoice.ChoiceParameter') 'TOA branches must be dynamic'
    Assert ($toa.SelectSingleNode("//parameterDefinitions/*[name='REPOSITORY_URL']/choices/a/string").InnerText -eq 'https://git.can-dao.com/flutter-business/toa-pos-flutter.git') 'TOA repository must be a dropdown'
    Assert ($null -eq $toa.SelectSingleNode("//parameterDefinitions/*[name='PROJECT' or name='PRODUCT' or name='DUFS_URL']")) 'TOA internal fields must be hidden'
    Assert (($toa.SelectNodes("//parameterDefinitions/*[name='ENVIRONMENT']/choices/a/string") | ForEach-Object InnerText) -join ',' -eq 'test-prod,pre-prod,release,debug,release-debug') 'TOA environment must remain test-prod'
    [xml]$general = Get-Content "$temp/xml/Candao-Windows-Package.xml" -Raw -Encoding UTF8
    Assert ($general.SelectSingleNode("//parameterDefinitions/*[name='PROJECT']/choices/a/string[1]").InnerText -eq 'queue-screen') 'General task defaults changed'
    & "$PSScriptRoot/sync-jobs.ps1" -RepositoryUrl 'https://example.invalid/package.git' -Branch 'feature/build' -OutputDirectory "$temp/explicit"
    [xml]$explicit = Get-Content "$temp/explicit/HPOS-Android-Package.xml" -Raw -Encoding UTF8
    Assert ($explicit.SelectSingleNode('//userRemoteConfigs/*/url').InnerText -eq 'https://example.invalid/package.git') 'Explicit remote ignored'
    Assert ($explicit.SelectSingleNode('//branches/*/name').InnerText -eq '*/feature/build') 'Explicit branch ignored'
    # Execute the real Windows preflight with filesystem/SDK probes mocked.
    $windowsPipeline = Get-Content "$PSScriptRoot/windows.Jenkinsfile" -Raw -Encoding UTF8
    # Only the legacy self-checkout flow may clone a local dependency.
    foreach ($platform in @('windows', 'android')) {
        $pipeline = Get-Content "$PSScriptRoot/$platform.Jenkinsfile" -Raw -Encoding UTF8
        $dependency = [regex]::Match($pipeline, '(?s)if \(\$env:PROJECT[^\r\n]+\) \{\s+git clone.*?\n          \}').Value.Replace('\\', '\')
        Assert ($dependency.Length -gt 0) 'Dependency checkout not found'
        & {
            function git { $script:gitCalls++; $global:LASTEXITCODE = 0 }
            foreach ($project in @('toa-pos', 'self-checkout', 'queue-screen')) {
                $env:PROJECT = $project
                $script:gitCalls = 0
                & ([scriptblock]::Create($dependency))
                $expected = if ($project -eq 'self-checkout') { 2 } else { 0 }
                Assert ($script:gitCalls -eq $expected) "Wrong dependency checkout for $platform / $project"
            }
            function git { $global:LASTEXITCODE = 1 }
            $env:PROJECT = 'self-checkout'
            Expect-Failure { & ([scriptblock]::Create($dependency)) }
            $env:PROJECT = ''
        }
    }
    $preflight = [regex]::Match($windowsPipeline, "(?s)stage\('Preflight'\).*?powershell '''(.*?)'''").Groups[1].Value.Replace('\\', '\')
    Assert ($preflight.Length -gt 0) 'Windows preflight not found'
    & {
        $env:PROJECT = 'toa-pos'
        $script:hasFvmrc = $false
        $script:sdkVersion = '3.41.9'
        function Test-Path { param($LiteralPath) if ($LiteralPath -eq '.fvmrc') { return $script:hasFvmrc }; return $true }
        function Get-Command { return 'fvm' }
        function Get-Content { if (!$script:hasFvmrc) { throw 'Missing .fvmrc' }; return '{"flutter":"3.41.9"}' }
        function git { $global:LASTEXITCODE = 0; return $script:sdkVersion }
        function Push-Location { }
        function Pop-Location { }
        function New-Item { }
        & ([scriptblock]::Create($preflight))
        $script:sdkVersion = '3.38.9'
        Expect-Failure { & ([scriptblock]::Create($preflight)) }
        $script:hasFvmrc = $true
        Expect-Failure { & ([scriptblock]::Create($preflight)) }
        $script:sdkVersion = '3.41.9'
        & ([scriptblock]::Create($preflight))
        $script:hasFvmrc = $false
        $env:PROJECT = 'self-checkout'
        Expect-Failure { & ([scriptblock]::Create($preflight)) }
        $env:PROJECT = ''
    }
    # Updating a job must preserve unrelated properties and replace old parameters.
    & {
        $env:JENKINS_USER = 'offline-test'; $env:JENKINS_API_TOKEN = 'offline-test'
        function Invoke-RestMethod { return @{ crumbRequestField = 'Jenkins-Crumb'; crumb = 'offline' } }
        function Invoke-WebRequest {
            param($Method, $Uri, $Headers, $WebSession, $ContentType, $Body, [switch]$UseBasicParsing)
            if ($Method -eq 'Post') {
                [xml]$updated = [Text.Encoding]::UTF8.GetString($Body)
                Assert ($updated.SelectSingleNode('//properties/example.Keep/value').InnerText -eq 'keep') 'Lost existing job property'
                Assert ($updated.SelectNodes('//hudson.model.ParametersDefinitionProperty').Count -eq 1) 'Duplicate parameter definitions'
                if ($Uri -notmatch '/TOA-POS-Windows/') {
                    Assert ($updated.SelectSingleNode('//description').InnerText -eq 'keep description') 'Lost job description'
                }
            } else {
                return @{ Content = '<flow-definition><description>keep description</description><properties><example.Keep><value>keep</value></example.Keep><hudson.model.ParametersDefinitionProperty/></properties><definition><script>old</script><sandbox>true</sandbox></definition></flow-definition>' }
            }
        }
        & "$PSScriptRoot/sync-jobs.ps1"
    }
    # Use two real branches to prove selection and rejection, including paths with spaces.
    git init -q --initial-branch main repo
    git -C repo -c user.name=Test -c user.email=test@example.invalid commit -q --allow-empty -m base
    git -C repo checkout -q -b feature/build
    git -C repo -c user.name=Test -c user.email=test@example.invalid commit -q --allow-empty -m feature
    $expected = git -C repo rev-parse HEAD
    git -C repo checkout -q main
    $env:REPOSITORY_URL = (Join-Path $temp repo)
    $env:BRANCH = 'feature/build'
    Checkout-Source 'unused'
    Assert ((git -C source rev-parse HEAD) -eq $expected) 'Wrong branch checked out'
    Remove-Item source -Recurse -Force
    git -C repo remote add origin $env:REPOSITORY_URL
    $env:REPOSITORY_URL = ''
    Checkout-Source (Join-Path $temp repo)
    Assert ((git -C source rev-parse HEAD) -eq $expected) 'Default repository origin branch was not selected'
    Remove-Item source -Recurse -Force
    $env:REPOSITORY_URL = (Join-Path $temp repo)
    $env:BRANCH = 'missing-branch'
    Expect-Failure { Checkout-Source 'unused' }
    $env:BRANCH = '--upload-pack=bad'
    Expect-Failure { Checkout-Source 'unused' }

    $env:UPLOAD_DUFS = 'false'; $env:SEND_DINGTALK = 'false'; $env:DUFS_URL = ''
    Assert-DeliveryOptions
    $env:UPLOAD_DUFS = 'true'; $env:DUFS_CREDENTIALS_ID = 'test'
    Expect-Failure { Assert-DeliveryOptions }
    $env:DUFS_URL = 'http://dufs.example.invalid/packages'
    Assert-DeliveryOptions
    New-Item -ItemType Directory artifacts | Out-Null
    [IO.File]::WriteAllText("$temp/artifacts/test.apk", 'test artifact')
    $script:httpMethods = @()
    $script:corruptDownload = $false
    function Invoke-WebRequest {
        param($Method, $Uri, $Headers, $InFile, $OutFile, $ContentType, $MaximumRedirection, $TimeoutSec, [switch]$UseBasicParsing)
        $script:httpMethods += $Method
        if ($OutFile) {
            if ($script:corruptDownload) { [IO.File]::WriteAllText($OutFile, 'corrupt') }
            else { Copy-Item (Get-ChildItem artifacts -File | Select-Object -First 1).FullName $OutFile }
        }
    }
    Publish-Artifacts
    Assert ($script:httpMethods.Count -eq 2 -and $script:httpMethods[0] -eq 'Put') 'Expected PUT and verification GET'
    Assert (Test-Path dufs-links.txt) 'Missing verified download link'
    Move-Item artifacts/test.apk artifacts/test.aab
    Publish-Artifacts
    Assert ((Get-Content dufs-links.txt -Raw).Contains('test.aab')) 'AAB must be uploaded and verified'
    $script:corruptDownload = $true
    Expect-Failure { Publish-Artifacts }
    # Notify without uploading; reject DingTalk application errors even on HTTP success.
    Remove-Item dufs-links.txt
    $env:BRANCH = 'main'; Checkout-Source 'unused'
    $env:DINGTALK_WEBHOOK = 'https://oapi.dingtalk.com/robot/send?access_token=test'
    $script:errcode = 0
    function Invoke-RestMethod {
        param($Method, $Uri, $ContentType, $Body, $TimeoutSec, $MaximumRedirection)
        $payload = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
        Assert ($payload.text.content.Contains('push')) 'TOA robot requires the push keyword'
        Assert ($payload.text.content.Contains('DUFS upload disabled')) 'Independent notification missing'
        return @{ errcode = $script:errcode }
    }
    Send-BuildNotification
    $script:errcode = 310000
    Expect-Failure { Send-BuildNotification }
    Write-Output 'PASS: SCM configuration, Pipeline syntax, branch selection, upload checksum and notification errors'
} finally {
    Pop-Location
    Remove-Item -LiteralPath $temp -Recurse -Force
}
