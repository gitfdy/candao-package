param(
    [string]$JenkinsUrl = 'http://localhost:8080',
    [string]$RepositoryUrl,
    [string]$Branch,
    [string]$CredentialsId = '',
    [string[]]$JobName,
    # Render XML locally without contacting Jenkins or requiring credentials.
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
if (!$RepositoryUrl) {
    $RepositoryUrl = (& git -C $PSScriptRoot remote get-url origin)
    if ($LASTEXITCODE -ne 0 -or !$RepositoryUrl) { throw 'Cannot resolve origin; specify RepositoryUrl' }
    # Jenkins credentials must not be copied from a developer remote URL.
    $RepositoryUrl = $RepositoryUrl.Trim() -replace '^(https?://)[^/]*@', '$1'
}
if (!$Branch) {
    $Branch = (& git -C $PSScriptRoot branch --show-current).Trim()
    if ($LASTEXITCODE -ne 0 -or !$Branch) { throw 'Cannot determine pipeline Git branch' }
}
if ($RepositoryUrl -match '^https?://' -and ([uri]$RepositoryUrl).UserInfo) {
    throw 'Store Git credentials in Jenkins, not in RepositoryUrl'
}
if ($Branch -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $Branch.Contains('..')) {
    throw 'Invalid pipeline Git branch'
}
$jobs = @{
    'TAPPO-Android' = 'tappo-android.Jenkinsfile'
    'TAPPO-PHONE-Android' = 'tappo-phone-android.Jenkinsfile'
    'TOA-KIOSK-WINDOWS' = 'kiosk-windows.Jenkinsfile'
    'HPOS-Android-Package' = 'hpos.Jenkinsfile'
    'Candao-Windows-Package' = 'windows.Jenkinsfile'
    'TOA-POS-Windows' = 'toa-windows.Jenkinsfile'
    'Candao-Android-Package' = 'android.Jenkinsfile'
}

if (!$OutputDirectory) {
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
} else {
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
}

foreach ($name in $jobs.Keys) {
    if ($JobName -and $name -notin $JobName) { continue }
    $path = Join-Path $PSScriptRoot $jobs[$name]
    $source = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ($source.Contains('# @include common.ps1')) { throw "Unresolved include in $path" }
    $jobUrl = "$JenkinsUrl/job/$name/config.xml"
    $existing = $null
    if (!$OutputDirectory) {
        try {
            $existing = (Invoke-WebRequest -UseBasicParsing -Uri $jobUrl -Headers $headers -WebSession $session).Content
        } catch {
            if ([int]$_.Exception.Response.StatusCode -ne 404) { throw }
        }
    }
    if ($existing) {
        [xml]$xml = ($existing -replace '^<\?xml version="1[.]1"', '<?xml version="1.0"')
        if (!$xml.SelectSingleNode('/flow-definition/definition')) { throw "Cannot locate Pipeline definition in $name" }
        $destination = $jobUrl
    } else {
        [xml]$xml = '<flow-definition plugin="workflow-job"><description>Configurable package build, archive and optional distribution.</description><keepDependencies>false</keepDependencies><properties/><definition/><triggers/><disabled>false</disabled></flow-definition>'
        $destination = "$JenkinsUrl/createItem?name=$name"
    }
    $oldDefinition = $xml.SelectSingleNode('/flow-definition/definition')
    $newDefinition = $xml.CreateElement('definition')
    $newDefinition.SetAttribute('class', 'org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition')
    $newDefinition.SetAttribute('plugin', 'workflow-cps')
    $scm = $xml.CreateElement('scm')
    $scm.SetAttribute('class', 'hudson.plugins.git.GitSCM')
    $scm.SetAttribute('plugin', 'git')
    $scm.InnerXml = '<configVersion>2</configVersion><userRemoteConfigs><hudson.plugins.git.UserRemoteConfig><url/><credentialsId/></hudson.plugins.git.UserRemoteConfig></userRemoteConfigs><branches><hudson.plugins.git.BranchSpec><name/></hudson.plugins.git.BranchSpec></branches><doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations><submoduleCfg class="empty-list"/><extensions/>'
    $scm.SelectSingleNode('userRemoteConfigs/hudson.plugins.git.UserRemoteConfig/url').InnerText = $RepositoryUrl
    $scm.SelectSingleNode('userRemoteConfigs/hudson.plugins.git.UserRemoteConfig/credentialsId').InnerText = $CredentialsId
    $scm.SelectSingleNode('branches/hudson.plugins.git.BranchSpec/name').InnerText = "*/$Branch"
    $newDefinition.AppendChild($scm) | Out-Null
    foreach ($field in @{ scriptPath = "jenkins/$($jobs[$name])"; lightweight = 'true' }.GetEnumerator()) {
        $element = $xml.CreateElement($field.Key)
        $element.InnerText = $field.Value
        $newDefinition.AppendChild($element) | Out-Null
    }
    $xml.DocumentElement.ReplaceChild($newDefinition, $oldDefinition) | Out-Null
    if ($name -eq 'TOA-POS-Windows') {
        $xml.SelectSingleNode('/flow-definition/description').InnerText = 'TOA POS Flutter Windows installer. QC branch: devlop_qc; build type: test-prod. Source and Octopus dependency are checked out from private remote Git repositories using candao-git-new credentials. DUFS and DingTalk are optional and default off.'
    }
    $properties = $xml.SelectSingleNode('/flow-definition/properties')
    if (!$properties) {
        $properties = $xml.CreateElement('properties')
        $xml.DocumentElement.AppendChild($properties) | Out-Null
    }
    $old = $properties.SelectSingleNode('hudson.model.ParametersDefinitionProperty')
    if ($old) { $properties.RemoveChild($old) | Out-Null }
    $parameterProperty = $xml.CreateElement('hudson.model.ParametersDefinitionProperty')
    $definitions = $xml.CreateElement('parameterDefinitions')
    $parameterProperty.AppendChild($definitions) | Out-Null
    $properties.AppendChild($parameterProperty) | Out-Null
    # Keep Jenkins' form and Pipeline defaults in one source. Reject unfamiliar declarations.
    $block = [regex]::Match($source, '(?s)  parameters \{\s*\n(.*?)\n  \}').Groups[1].Value
    if (!$block) { throw "No parameters found in $path" }
    $dynamic = [regex]::Match($block, "(?sm)^    activeChoice\(name: 'BRANCH'.*?fallbackScript:.*?\)\)\s*$")
    if ($dynamic.Success) {
        $branchScript = [regex]::Match($dynamic.Value, "(?s)script: '''(.*?)'''").Groups[1].Value
        $parameter = $xml.CreateElement('org.biouno.unochoice.ChoiceParameter')
        $parameter.SetAttribute('plugin', 'uno-choice')
        $parameter.InnerXml = '<name>BRANCH</name><description>GitLab remote branches; searchable, defaults to devlop_qc</description><randomName>remote-branch</randomName><visibleItemCount>10</visibleItemCount><choiceType>PT_SINGLE_SELECT</choiceType><filterable>true</filterable><filterLength>1</filterLength><script class="org.biouno.unochoice.model.GroovyScript"><secureScript><script/><sandbox>false</sandbox></secureScript><secureFallbackScript><script>return ["Unable to read remote branches:disabled"]</script><sandbox>true</sandbox></secureFallbackScript></script>'
        $parameter.SelectSingleNode('description').InnerText = 'GitLab remote branches; searchable'
        $parameter.SelectSingleNode('script/secureScript/script').InnerText = $branchScript
        $definitions.AppendChild($parameter) | Out-Null
        $block = $block.Remove($dynamic.Index, $dynamic.Length)
    }
    $signing = [regex]::Match($block, "(?m)^    credentials\(name: 'SIGNING_KEY'.*$")
    if ($signing.Success) {
        $parameter = $xml.CreateElement('com.cloudbees.plugins.credentials.CredentialsParameterDefinition')
        $parameter.InnerXml = '<name>SIGNING_KEY</name><description>Select an uploaded signing key. No key means internal test signing; Tappo Phone AAB requires the original Play upload key.</description><defaultValue/><credentialType>org.jenkinsci.plugins.plaincredentials.FileCredentials</credentialType><required>false</required>'
        $definitions.AppendChild($parameter) | Out-Null
        $block = $block.Remove($signing.Index, $signing.Length)
    }
    foreach ($line in ($block -split '\r?\n')) {
        if (!$line.Trim()) { continue }
        $match = [regex]::Match($line.Trim(), "^(string|choice|booleanParam)\(name: '([^']+)', (defaultValue|choices): (.*), description: '([^']*)'(, trim: true)?\)$")
        if (!$match.Success) { throw "Unsupported parameter declaration: $line" }
        $type, $parameterName, $value, $description = $match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[4].Value, $match.Groups[5].Value
        # Resolve the same job-specific defaults that Declarative Pipeline evaluates at runtime.
        $conditional = [regex]::Match($value, "^env[.]JOB_BASE_NAME == '([^']+)' \? (.*?) : (.*)$")
        if ($conditional.Success) {
            $value = if ($name -eq $conditional.Groups[1].Value) { $conditional.Groups[2].Value } else { $conditional.Groups[3].Value }
        }
        $class = switch ($type) { 'string' { 'String' }; 'choice' { 'Choice' }; 'booleanParam' { 'Boolean' } }
        $definition = $xml.CreateElement("hudson.model.${class}ParameterDefinition")
        foreach ($field in @{ name = $parameterName; description = $description }.GetEnumerator()) {
            $element = $xml.CreateElement($field.Key)
            $element.InnerText = $field.Value
            $definition.AppendChild($element) | Out-Null
        }
        if ($type -eq 'choice') {
            $choices = $xml.CreateElement('choices')
            $choices.SetAttribute('class', 'java.util.Arrays$ArrayList')
            $items = $xml.CreateElement('a')
            $items.SetAttribute('class', 'string-array')
            foreach ($item in [regex]::Matches($value, "'([^']*)'")) {
                $element = $xml.CreateElement('string')
                $element.InnerText = $item.Groups[1].Value
                $items.AppendChild($element) | Out-Null
            }
            $choices.AppendChild($items) | Out-Null
            $definition.AppendChild($choices) | Out-Null
        } else {
            $element = $xml.CreateElement('defaultValue')
            $element.InnerText = $value.Trim("'")
            $definition.AppendChild($element) | Out-Null
            if ($type -eq 'string') {
                $element = $xml.CreateElement('trim')
                $element.InnerText = 'true'
                $definition.AppendChild($element) | Out-Null
            }
        }
        $definitions.AppendChild($definition) | Out-Null
    }
    if ($OutputDirectory) {
        $xml.Save((Join-Path (Resolve-Path $OutputDirectory).Path "$name.xml"))
        Write-Output "Rendered $name"
    } else {
        Invoke-WebRequest -UseBasicParsing -Method Post -Uri $destination -Headers $headers -WebSession $session `
            -ContentType 'application/xml; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($xml.OuterXml)) | Out-Null
        Write-Output "Synchronized $name (parameters available immediately)"
    }
}
