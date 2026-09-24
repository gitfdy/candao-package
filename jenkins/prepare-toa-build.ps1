# Adapt only the disposable Jenkins checkout. Keep the branch's installer logic.
function Prepare-ToaBuild(
    [string]$SourceDirectory,
    [string]$Environment,
    [ValidateSet('true', 'false')][string]$IncidentUploadEnabled = 'false'
) {
    if ($Environment -notin @('test-prod', 'pre-prod', 'release', 'debug', 'release-debug')) {
        throw 'Unsupported TOA environment'
    }
    $path = Join-Path $SourceDirectory 'scripts/build_windows.bat'
    $script = [IO.File]::ReadAllText($path)
    if (!$script.Contains('"' + $Environment + '" (')) {
        throw "Selected source does not implement build type $Environment"
    }
    if ($Environment -in @('test-prod', 'pre-prod')) {
        $define = if ($Environment -eq 'pre-prod') { 'pre_production' } else { 'test_production' }
        $main = [IO.File]::ReadAllText((Join-Path $SourceDirectory 'lib/main.dart'))
        if (!$main.Contains("String.fromEnvironment('$define'")) {
            throw "Selected source does not consume $define; refusing to build the wrong environment"
        }
    }
    $incidentLabel = '(?m)^:require_incident_config\r?$'
    if ($IncidentUploadEnabled -eq 'true') {
        if ($script -notmatch $incidentLabel -or !$script.Contains('if /i "%BUILD_TYPE%"=="' + $Environment + '" goto :require_incident_config')) {
            throw 'Selected source/build type does not support Incident upload'
        }
        $uri = $null
        $url = $env:TOA_INCIDENT_API_BASE_URL
        if ($url -notmatch '^https://[A-Za-z0-9._~:/-]+$' -or
            ![Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -ne 'https' -or !$uri.Host -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
            throw 'Incident upload requires TOA_INCIDENT_API_BASE_URL with a safe HTTPS URL'
        }
    } elseif ($script -match $incidentLabel) {
        # Only adapt the Jenkins checkout; preserve the upstream enabled path and build manifest.
        $disabled = ":require_incident_config`r`n" +
            'set "BUILD_PARAMS=!BUILD_PARAMS! --dart-define=TOA_INCIDENT_UPLOAD_ENABLED=false"' +
            "`r`ngoto :incident_config_ready"
        $script = [regex]::Replace($script, $incidentLabel, $disabled)
    }
    Write-Output "Incident upload enabled: $IncidentUploadEnabled"
    # Newer TOA scripts route release through Shorebird even with --local true.
    $dispatch = 'if "%BUILD_TYPE%"=="release" goto :build_shorebird_windows'
    if ($Environment -eq 'release' -and $script.Contains($dispatch)) {
        if (!$script.Contains(':build_flutter_windows')) { throw 'Missing plain Flutter build entrypoint' }
        $script = $script.Replace($dispatch, 'if "%BUILD_TYPE%"=="release" goto :build_flutter_windows')
    } elseif ($Environment -eq 'release' -and $script -match '(?i)shorebird[^\r\n]*release|goto :build_shorebird') {
        throw 'Unrecognized Shorebird release routing; cannot guarantee a local-only build'
    }
    $command = 'call %FLUTTER_CMD% build windows --%BUILD_MODE% %BUILD_PARAMS%'
    if (!$script.Contains($command)) { throw 'Unrecognized Flutter build command' }
    $script = $script.Replace($command, "$command`r`nif errorlevel 1 exit /b 1")
    [IO.File]::WriteAllText($path, $script, [Text.UTF8Encoding]::new($false))
}
