pipeline {
  agent any
  options {
    disableConcurrentBuilds()
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '20'))
  }
  environment {
    FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
    PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
    PUB_CACHE = 'C:\\Users\\Administrator\\AppData\\Local\\Pub\\Cache'
  }
  parameters {
    choice(name: 'PROJECT', choices: ['queue-screen', 'self-checkout', 'toa-pos'], description: 'Windows application')
    choice(name: 'ENVIRONMENT', choices: ['qc', 'release', 'staging', 'test-prod'], description: 'Allowed values depend on the project')
    choice(name: 'PRODUCT', choices: ['self_checkout', 'kiosk'], description: 'Used by self-checkout only')
  }
  stages {
    stage('Validate and checkout') {
      steps {
        deleteDir()
        powershell '''
          $ErrorActionPreference = 'Stop'
          $sources = @{
            'queue-screen' = 'D:\\work\\toa-meal-pick-up-screen-flutter'
            'self-checkout' = 'D:\\work\\self-checkout'
            'toa-pos' = 'D:\\work\\toa-pos-flutter'
          }
          $allowed = @{
            'queue-screen' = @('qc', 'release')
            'self-checkout' = @('staging', 'release')
            'toa-pos' = @('test-prod')
          }
          if (!$sources.ContainsKey($env:PROJECT) -or $env:ENVIRONMENT -notin $allowed[$env:PROJECT]) {
            throw "Unsupported project/environment pair: $env:PROJECT / $env:ENVIRONMENT"
          }
          $repo = $sources[$env:PROJECT]
          if (!(Test-Path -LiteralPath "$repo\\.git")) { throw "Missing source repository: $repo" }
          git clone --local --no-hardlinks -- $repo source
          if ($LASTEXITCODE -ne 0) { throw 'Git clone failed' }
          git -C source rev-parse HEAD
          if ($LASTEXITCODE -ne 0) { throw 'Git revision lookup failed' }
          if ($env:PROJECT -eq 'self-checkout') {
            git clone --local --no-hardlinks -- 'D:\\work\\octopus_payment_flutter' octopus_payment_flutter
            if ($LASTEXITCODE -ne 0) { throw 'Octopus dependency clone failed' }
            git -C octopus_payment_flutter rev-parse HEAD
          }
        '''
      }
    }
    stage('Preflight') {
      steps {
        powershell '''
          $ErrorActionPreference = 'Stop'
          if (!(Test-Path -LiteralPath 'C:\\Program Files (x86)\\Inno Setup 6\\ISCC.exe')) { throw 'Inno Setup 6 is missing' }
          if ($env:PROJECT -ne 'queue-screen') {
            if (!(Get-Command fvm -ErrorAction SilentlyContinue)) { throw 'FVM is missing' }
            $sdk = switch ($env:PROJECT) {
              'self-checkout' { 'D:\\work\\self-checkout\\.fvm\\flutter_sdk' }
              'toa-pos' { 'D:\\work\\candao-package\\.jenkins-sdk\\flutter-3.41.9' }
            }
            if (!(Test-Path -LiteralPath "$sdk\\bin\\flutter.bat")) { throw "Flutter SDK missing: $sdk" }
            Push-Location source
            try {
              $requiredVersion = (Get-Content -LiteralPath '.fvmrc' -Raw | ConvertFrom-Json).flutter
              $actualVersion = (& git -C $sdk describe --tags --exact-match).Trim()
              if ($LASTEXITCODE -ne 0 -or $actualVersion -ne $requiredVersion) { throw "Flutter SDK mismatch: required $requiredVersion, found $actualVersion" }
              New-Item -ItemType Directory -Force -Path '.fvm' | Out-Null
              New-Item -ItemType Junction -Path '.fvm\\flutter_sdk' -Target $sdk | Out-Null
            } finally { Pop-Location }
          }
        '''
      }
    }
    stage('Build installer') {
      steps {
        dir('source') {
          timeout(time: 60, unit: 'MINUTES') {
          powershell '''
            $ErrorActionPreference = 'Stop'
            if ($env:PROJECT -ne 'queue-screen') {
              $env:PATH = "$((Get-Location).Path)\\.fvm\\flutter_sdk\\bin;C:\\ProgramData\\chocolatey\\bin;$env:PATH"
            }
            $sdkLock = $null
            if ($env:PROJECT -ne 'queue-screen') {
              $lockPath = "D:\\work\\candao-package\\.jenkins-sdk\\${env:PROJECT}-sdk.lock"
              while ($null -eq $sdkLock) {
                try { $sdkLock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
                catch [IO.IOException] { Start-Sleep -Seconds 5 }
              }
            }
            try {
            if ($env:PROJECT -eq 'toa-pos') {
              $flutter = '.\\.fvm\\flutter_sdk\\bin\\flutter.bat'
              for ($attempt = 1; $attempt -le 3; $attempt++) {
                & $flutter precache --windows
                if ($LASTEXITCODE -eq 0) { break }
                if ($attempt -lt 3) { Start-Sleep -Seconds 10 }
              }
              if ($LASTEXITCODE -ne 0) { throw 'Flutter SDK artifact download failed after three attempts' }
            }
            switch ($env:PROJECT) {
              'queue-screen' {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\core\\build-package.ps1 -Env $env:ENVIRONMENT
              }
              'self-checkout' {
                & .\\scripts\\build_windows.bat --product $env:PRODUCT --type $env:ENVIRONMENT --local true
              }
              'toa-pos' {
                & .\\scripts\\build_windows.bat --type test-prod --proxy none --local true
              }
            }
            if ($LASTEXITCODE -ne 0) { throw "Installer build failed: $LASTEXITCODE" }
            } finally { if ($sdkLock) { $sdkLock.Dispose() } }
          '''
          }
        }
      }
    }
    stage('Verify and archive') {
      steps {
        powershell '''
          $ErrorActionPreference = 'Stop'
          $files = @(Get-ChildItem -LiteralPath 'source\\build\\outputs' -Filter '*.exe' -File -ErrorAction Stop)
          if ($env:PROJECT -eq 'queue-screen') {
            $suffix = if ($env:ENVIRONMENT -eq 'qc') { '_qc' } else { '' }
            $names = @("queue_screen_caller$suffix.exe", "queue_screen_other$suffix.exe")
            $files = @($files | Where-Object { $_.Name -in $names })
            if ($files.Count -ne 2) { throw 'Both Caller and Other installers are required' }
          } else {
            $files = @($files | Where-Object { $_.LastWriteTime -ge (Get-Date).AddHours(-2) })
            if ($files.Count -lt 1) { throw 'No fresh installer found' }
          }
          New-Item -ItemType Directory -Force -Path artifacts | Out-Null
          $sha = (git -C source rev-parse --short=12 HEAD).Trim()
          foreach ($file in $files) {
            if ($file.Length -le 0) { throw "Empty installer: $($file.FullName)" }
            $name = "${env:PROJECT}_${env:ENVIRONMENT}_${sha}_${env:BUILD_NUMBER}_$($file.Name)"
            $target = Join-Path artifacts $name
            Copy-Item -LiteralPath $file.FullName -Destination $target
            Get-FileHash -Algorithm SHA256 -LiteralPath $target | Format-List
          }
        '''
        archiveArtifacts artifacts: 'artifacts/*.exe', fingerprint: true
      }
    }
  }
}
