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
        [xml]$xml = Get-Content $file -Raw
        $parameters = $xml.SelectNodes('//parameterDefinitions/*')
        foreach ($name in @('REPOSITORY_URL', 'BRANCH', 'UPLOAD_DUFS', 'SEND_DINGTALK')) {
            Assert ($name -in $parameters.name) "Missing parameter: $name"
        }
        Assert ($xml.SelectSingleNode("//parameterDefinitions/*[name='UPLOAD_DUFS']/defaultValue").InnerText -eq 'false') 'Upload must default off'
        Assert ($xml.SelectSingleNode("//parameterDefinitions/*[name='SEND_DINGTALK']/defaultValue").InnerText -eq 'false') 'Notification must default off'
        $pipeline = $xml.SelectSingleNode('//definition/script').InnerText
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
    Write-Output 'PASS: parameter XML, embedded syntax, branch selection, upload checksum and notification errors'
} finally {
    Pop-Location
    Remove-Item -LiteralPath $temp -Recurse -Force
}
