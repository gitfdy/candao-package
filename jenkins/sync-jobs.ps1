param(
    [string]$JenkinsUrl = 'http://localhost:8080',
    # Render XML locally without contacting Jenkins or requiring credentials.
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$jobs = @{
    'HPOS-Android-Package' = 'hpos.Jenkinsfile'
    'Candao-Windows-Package' = 'windows.Jenkinsfile'
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
    $path = Join-Path $PSScriptRoot $jobs[$name]
    $source = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    # Groovy triple-single-quoted strings still interpret backslash escapes.
    $common = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'common.ps1') -Raw -Encoding UTF8).Replace('\', '\\').Replace("'", "\'")
    $script = $source.Replace('# @include common.ps1', $common)
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
        [xml]$xml = $existing
        if (!$xml.SelectSingleNode('/flow-definition/definition/script')) { throw "Cannot locate inline Pipeline script in $name" }
        $destination = $jobUrl
    } else {
        [xml]$xml = '<flow-definition plugin="workflow-job"><description>Configurable package build, archive and optional distribution.</description><keepDependencies>false</keepDependencies><properties/><definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps"><script/><sandbox>true</sandbox></definition><triggers/><disabled>false</disabled></flow-definition>'
        $destination = "$JenkinsUrl/createItem?name=$name"
    }
    $xml.SelectSingleNode('/flow-definition/definition/script').InnerText = $script
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
    foreach ($line in ($block -split '\r?\n')) {
        if (!$line.Trim()) { continue }
        $match = [regex]::Match($line.Trim(), "^(string|choice|booleanParam)\(name: '([^']+)', (defaultValue|choices): (.*), description: '([^']*)'(, trim: true)?\)$")
        if (!$match.Success) { throw "Unsupported parameter declaration: $line" }
        $type, $parameterName, $value, $description = $match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[4].Value, $match.Groups[5].Value
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
