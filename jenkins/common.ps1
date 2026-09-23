# Embedded by sync-jobs.ps1; no dependency on files on the build node.
function Checkout-Source([string]$DefaultRepo) {
    $repo = $env:REPOSITORY_URL
    $branch = $env:BRANCH
    if ([string]::IsNullOrWhiteSpace($repo)) {
        $repo = $DefaultRepo
        if (![string]::IsNullOrWhiteSpace($branch)) {
            $repo = (& git -C $DefaultRepo remote get-url origin)
            if ($LASTEXITCODE -ne 0 -or !$repo) { throw 'Cannot resolve origin; specify REPOSITORY_URL' }
        }
    }
    if ($repo -match '^https?://' -and ([uri]$repo).UserInfo) { throw 'Use node Git credentials, not credentials in REPOSITORY_URL' }
    $cloneArgs = @('clone', '--no-hardlinks')
    if (![string]::IsNullOrWhiteSpace($branch)) {
        & git check-ref-format --branch $branch | Out-Null
        if ($LASTEXITCODE -ne 0 -or $branch.StartsWith('-')) { throw 'BRANCH must be a valid branch name' }
        $cloneArgs += @('--single-branch', '--branch', $branch)
    }
    $cloneArgs += @('--', $repo, 'source')
    & git @cloneArgs
    if ($LASTEXITCODE -ne 0) { throw 'Git clone failed' }
    if (![string]::IsNullOrWhiteSpace($branch)) {
        $actualBranch = & git -C source symbolic-ref --short HEAD
        if ($LASTEXITCODE -ne 0 -or $actualBranch -ne $branch) { throw 'BRANCH must select a branch, not a tag' }
    }
    & git -C source rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Git revision lookup failed' }
}

function Assert-DeliveryOptions {
    if ($env:PROJECT -eq 'self-checkout' -and $env:PRODUCT -notin @('self_checkout', 'kiosk')) {
        throw 'Unsupported self-checkout product'
    }
    if ($env:UPLOAD_DUFS -eq 'true') {
        $url = $null
        if (![uri]::TryCreate($env:DUFS_URL, [UriKind]::Absolute, [ref]$url) -or
            $url.Scheme -notin @('http', 'https') -or $url.UserInfo -or $url.Query -or $url.Fragment) {
            throw 'DUFS_URL must be an HTTP(S) directory URL without credentials, query or fragment'
        }
        if ([string]::IsNullOrWhiteSpace($env:DUFS_CREDENTIALS_ID)) { throw 'DUFS_CREDENTIALS_ID is required' }
    }
    if ($env:SEND_DINGTALK -eq 'true' -and [string]::IsNullOrWhiteSpace($env:DINGTALK_CREDENTIALS_ID)) {
        throw 'DINGTALK_CREDENTIALS_ID is required'
    }
}

function Publish-Artifacts {
    Assert-DeliveryOptions
    $files = @(Get-ChildItem -LiteralPath artifacts -File | Where-Object { $_.Extension -in @('.apk', '.exe') })
    if (!$files.Count) { throw 'No artifacts to upload' }
    $auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${env:DUFS_USER}:${env:DUFS_PASSWORD}"))
    $headers = @{ Authorization = "Basic $auth" }
    $links = @()
    foreach ($file in $files) {
        $url = $env:DUFS_URL.TrimEnd('/') + '/' + [uri]::EscapeDataString($file.Name)
        # A downloaded digest verifies stored bytes, not just a successful PUT response.
        $download = [IO.Path]::GetTempFileName()
        try {
            Invoke-WebRequest -UseBasicParsing -Method Put -Uri $url -Headers $headers -InFile $file.FullName -ContentType 'application/octet-stream' -MaximumRedirection 0 -TimeoutSec 600 | Out-Null
            Invoke-WebRequest -UseBasicParsing -Uri $url -Headers $headers -OutFile $download -MaximumRedirection 0 -TimeoutSec 600 | Out-Null
            if ((Get-FileHash $download -Algorithm SHA256).Hash -ne (Get-FileHash $file.FullName -Algorithm SHA256).Hash) {
                throw 'Uploaded artifact checksum mismatch'
            }
        } finally { Remove-Item -LiteralPath $download -Force }
        $links += $url
        Write-Output "Verified DUFS upload: $($file.Name)"
    }
    [IO.File]::WriteAllLines((Join-Path (Get-Location).Path 'dufs-links.txt'), $links, [Text.UTF8Encoding]::new($false))
}

function Send-BuildNotification {
    $webhook = [uri]$env:DINGTALK_WEBHOOK
    if ($webhook.Scheme -ne 'https' -or $webhook.Host -ne 'oapi.dingtalk.com' -or $webhook.AbsolutePath -ne '/robot/send') {
        throw 'DingTalk credential must contain an HTTPS robot webhook'
    }
    $links = if (Test-Path -LiteralPath dufs-links.txt) { Get-Content -LiteralPath dufs-links.txt -Raw } else { 'DUFS upload disabled; artifacts are available in Jenkins.' }
    $sha = (& git -C source rev-parse HEAD)
    if ($LASTEXITCODE -ne 0) { throw 'Git revision lookup failed' }
    $buildEnvironment = if ($env:BUILD_TYPE) { $env:BUILD_TYPE } else { $env:ENVIRONMENT }
    $content = "Candao build completed: $env:JOB_NAME #$env:BUILD_NUMBER`nEnvironment: $buildEnvironment`nBranch: $env:BRANCH`nCommit: $sha`n$env:BUILD_URL`n$links"
    $body = @{ msgtype = 'text'; text = @{ content = $content } } | ConvertTo-Json -Depth 3
    # Do not expose the webhook (including its token) in an HTTP exception.
    try {
        $result = Invoke-RestMethod -Method Post -Uri $webhook -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 30 -MaximumRedirection 0
    } catch { throw 'DingTalk HTTP request failed; check the Jenkins secret and network' }
    if ($null -eq $result.errcode -or $result.errcode -ne 0) { throw "DingTalk rejected notification (errcode: $($result.errcode))" }
    Write-Output 'DingTalk notification accepted'
}
