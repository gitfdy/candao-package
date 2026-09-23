pipeline {
  agent any
  options {
    skipDefaultCheckout(true)
    disableConcurrentBuilds()
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '20'))
  }
  environment {
    DUFS_CREDENTIALS_ID = 'dufs'
    DINGTALK_CREDENTIALS_ID = 'dingtalk-webhook'
    FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
    PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
    PUB_CACHE = 'C:\\Users\\Administrator\\AppData\\Local\\Pub\\Cache'
  }
  parameters {
    string(name: 'REPOSITORY_URL', defaultValue: env.JOB_BASE_NAME == 'TOA-POS-Windows-Package' ? 'D:/work/toa-pos-flutter' : '', description: '源码仓库 URL 或节点本地路径；指定本地路径时读取该仓库已提交代码', trim: true)
    string(name: 'BRANCH', defaultValue: env.JOB_BASE_NAME == 'TOA-POS-Windows-Package' ? 'devlop_qc' : '', description: 'TOA QC 分支为 devlop_qc；按指定仓库获取分支，留空使用仓库默认分支', trim: true)
    booleanParam(name: 'UPLOAD_DUFS', defaultValue: false, description: '构建并归档成功后上传 DUFS')
    string(name: 'DUFS_URL', defaultValue: env.JOB_BASE_NAME == 'TOA-POS-Windows-Package' ? 'http://192.168.225.46:5000/dufs/TOA-POS-Windows' : '', description: 'DUFS 目标目录完整 URL；TOA Windows 已预填，其他项目开启上传时填写', trim: true)
    booleanParam(name: 'SEND_DINGTALK', defaultValue: false, description: '构建成功后发送钉钉通知；可独立于 DUFS 开启')
    choice(name: 'PROJECT', choices: env.JOB_BASE_NAME == 'TOA-POS-Windows-Package' ? ['toa-pos'] : ['queue-screen', 'self-checkout', 'toa-pos'], description: 'Windows application')
    choice(name: 'ENVIRONMENT', choices: env.JOB_BASE_NAME == 'TOA-POS-Windows-Package' ? ['test-prod'] : ['qc', 'release', 'staging', 'test-prod'], description: 'TOA QC 使用 test-prod；Git 分支与构建环境是不同参数')
    choice(name: 'PRODUCT', choices: ['self_checkout', 'kiosk'], description: 'Used by self-checkout only')
  }
  stages {
    stage('Validate and checkout') {
      steps {
        deleteDir()
        checkout scm
        powershell '''
          $ErrorActionPreference = 'Stop'
          . "$env:WORKSPACE/jenkins/common.ps1"
          Assert-DeliveryOptions
          if ($env:JOB_BASE_NAME -eq 'TOA-POS-Windows-Package' -and ($env:PROJECT -ne 'toa-pos' -or $env:ENVIRONMENT -ne 'test-prod')) {
            throw 'The TOA POS Windows task only builds toa-pos / test-prod'
          }
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
          Checkout-Source $repo
          if ($env:PROJECT -in @('self-checkout', 'toa-pos')) {
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
              if (Test-Path -LiteralPath '.fvmrc') {
                $requiredVersion = (Get-Content -LiteralPath '.fvmrc' -Raw | ConvertFrom-Json).flutter
              } elseif ($env:PROJECT -eq 'toa-pos') {
                # Older TOA branches do not commit FVM metadata; use the configured CI SDK.
                $requiredVersion = '3.41.9'
                Write-Output 'No committed .fvmrc; using configured TOA CI SDK 3.41.9'
              } else {
                throw 'Source repository must commit .fvmrc'
              }
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
                & .\\scripts\\build_windows.bat --type $env:ENVIRONMENT --proxy none --local true
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
    stage('Upload DUFS') {
      when { expression { params.UPLOAD_DUFS } }
      steps {
        withCredentials([usernamePassword(credentialsId: env.DUFS_CREDENTIALS_ID, usernameVariable: 'DUFS_USER', passwordVariable: 'DUFS_PASSWORD')]) {
          powershell '''
            $ErrorActionPreference = 'Stop'
            . "$env:WORKSPACE/jenkins/common.ps1"
            Publish-Artifacts
          '''
        }
        archiveArtifacts artifacts: 'dufs-links.txt'
      }
    }
    stage('Notify DingTalk') {
      when { expression { params.SEND_DINGTALK } }
      steps {
        withCredentials([string(credentialsId: env.DINGTALK_CREDENTIALS_ID, variable: 'DINGTALK_WEBHOOK')]) {
          powershell '''
            $ErrorActionPreference = 'Stop'
            . "$env:WORKSPACE/jenkins/common.ps1"
            Send-BuildNotification
          '''
        }
      }
    }
  }
}
