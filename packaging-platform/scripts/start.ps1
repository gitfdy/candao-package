$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
if (!(Get-Command node -ErrorAction SilentlyContinue)) { throw 'Install Node.js 24 LTS first.' }
$major = & node -p 'process.versions.node.split(".")[0]'
if ($major -ne '24') { throw 'This application requires Node.js 24 LTS.' }
if (!(Test-Path 'config.local.json')) { throw 'Copy config.example.json to config.local.json and configure it first.' }
if (!(Test-Path 'dist/index.html')) { throw 'Run npm ci and npm run build first.' }
& node server/index.js
exit $LASTEXITCODE
