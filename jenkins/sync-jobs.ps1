param(
    [string]$JenkinsUrl = 'http://localhost:8080'
)

$ErrorActionPreference = 'Stop'
$user = $env:JENKINS_USER
$token = $env:JENKINS_API_TOKEN
if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($token)) {
    throw 'Set JENKINS_USER and JENKINS_API_TOKEN in the current process before running this script.'
}

$auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${user}:${token}"))
$session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
$headers = @{ Authorization = "Basic $auth" }
$crumb = Invoke-RestMethod -Uri "$JenkinsUrl/crumbIssuer/api/json" -Headers $headers -WebSession $session
$headers[$crumb.crumbRequestField] = $crumb.crumb

$jobs = @{
    'HPOS-Android-Package' = 'hpos.Jenkinsfile'
    'Candao-Windows-Package' = 'windows.Jenkinsfile'
    'Candao-Android-Package' = 'android.Jenkinsfile'
}

foreach ($name in $jobs.Keys) {
    $path = Join-Path $PSScriptRoot $jobs[$name]
    $script = [Security.SecurityElement]::Escape((Get-Content -LiteralPath $path -Raw))
    $jobUrl = "$JenkinsUrl/job/$name/config.xml"
    $existing = $null
    try {
        $existing = (Invoke-WebRequest -Uri $jobUrl -Headers $headers -WebSession $session).Content
    } catch {
        if ([int]$_.Exception.Response.StatusCode -ne 404) { throw }
    }

    if ($existing) {
        $replacement = '<script>' + $script + '</script>'
        if ($existing -notmatch '<script>[\s\S]*?</script>') { throw "Cannot locate Pipeline script in $name" }
        $xml = [regex]::Replace($existing, '<script>[\s\S]*?</script>',
            [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $replacement }, 1)
        $destination = $jobUrl
    } else {
        $xml = '<flow-definition plugin="workflow-job"><description>Local package build and artifact archive.</description><keepDependencies>false</keepDependencies><properties/><definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps"><script>' + $script + '</script><sandbox>true</sandbox></definition><triggers/><disabled>false</disabled></flow-definition>'
        $destination = "$JenkinsUrl/createItem?name=$name"
    }

    Invoke-WebRequest -Method Post -Uri $destination -Headers $headers -WebSession $session `
        -ContentType 'application/xml; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($xml)) | Out-Null
    Write-Output "Synchronized $name"
}
