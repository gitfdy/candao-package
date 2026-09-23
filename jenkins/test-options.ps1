# Offline checks. HTTP is mocked; no Jenkins, DUFS or DingTalk writes.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"
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
    & "$PSScriptRoot/sync-jobs.ps1" -OutputDirectory "$temp/xml"
    foreach ($file in Get-ChildItem "$temp/xml/*.xml") {
        [xml]$xml = Get-Content $file -Raw -Encoding UTF8
        $parameters = $xml.SelectNodes('//parameterDefinitions/*')
        foreach ($name in @('REPOSITORY_URL', 'BRANCH', 'UPLOAD_DUFS', 'SEND_DINGTALK')) {
            Assert ($name -in $parameters.name) "Missing parameter: $name"
        }
        Assert ($xml.SelectSingleNode("//parameterDefinitions/*[name='UPLOAD_DUFS']/defaultValue").InnerText -eq 'false') 'Upload must default off'
        Assert ($xml.SelectSingleNode("//parameterDefinitions/*[name='SEND_DINGTALK']/defaultValue").InnerText -eq 'false') 'Notification must default off'
        $definition = $xml.SelectSingleNode('//definition')
        Assert ($definition.GetAttribute('class') -eq 'org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition') 'Pipeline must load from Git SCM'
        Assert ($definition.scriptPath -eq "jenkins/$($file.BaseName.Replace('HPOS-Android-Package', 'hpos').Replace('Candao-Windows-Package', 'windows').Replace('Candao-Android-Package', 'android')).Jenkinsfile") 'Wrong Jenkinsfile path'
        Assert ($definition.scm.userRemoteConfigs.'hudson.plugins.git.UserRemoteConfig'.url -eq ((git -C $PSScriptRoot remote get-url origin).Trim() -replace '^(https?://)[^/]*@', '$1')) 'Wrong Git repository'
        $pipeline = Get-Content (Join-Path $PSScriptRoot $definition.scriptPath.Replace('jenkins/', '')) -Raw
        Assert (!$pipeline.Contains('# @include')) 'Unexpanded helper'
        foreach ($match in [regex]::Matches($pipeline, "(?s)powershell '''(.*?)'''")) {
            $code = $match.Groups[1].Value.Replace('\\', '\').Replace("\'", "'")
            $errors = $null; $tokens = $null
            [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$errors) | Out-Null
            Assert (!$errors) "PowerShell parse error: $errors"
        }
        Assert ($pipeline.IndexOf("stage('Verify and archive')") -lt $pipeline.IndexOf("stage('Upload DUFS')")) 'Archive before upload'
        Assert ($pipeline.Contains('when { expression { params.UPLOAD_DUFS } }')) 'Missing upload guard'
        Assert ($pipeline.Contains('when { expression { params.SEND_DINGTALK } }')) 'Missing notification guard'
    }
    & "$PSScriptRoot/sync-jobs.ps1" -RepositoryUrl 'https://example.invalid/package.git' -Branch 'feature/build' -OutputDirectory "$temp/explicit"
    [xml]$explicit = Get-Content "$temp/explicit/HPOS-Android-Package.xml" -Raw -Encoding UTF8
    Assert ($explicit.SelectSingleNode('//userRemoteConfigs/*/url').InnerText -eq 'https://example.invalid/package.git') 'Explicit remote ignored'
    Assert ($explicit.SelectSingleNode('//branches/*/name').InnerText -eq '*/feature/build') 'Explicit branch ignored'
    # Execute the real Windows preflight with filesystem/SDK probes mocked.
    $windowsPipeline = Get-Content "$PSScriptRoot/windows.Jenkinsfile" -Raw -Encoding UTF8
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
                Assert ($updated.SelectSingleNode('//description').InnerText -eq 'keep description') 'Lost job description'
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
            else { Copy-Item artifacts/test.apk $OutFile }
        }
    }
    Publish-Artifacts
    Assert ($script:httpMethods.Count -eq 2 -and $script:httpMethods[0] -eq 'Put') 'Expected PUT and verification GET'
    Assert (Test-Path dufs-links.txt) 'Missing verified download link'
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
