pipeline {
  agent any
  options {
    disableConcurrentBuilds()
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '20'))
  }
  parameters {
    string(name: 'REPOSITORY_URL', defaultValue: '', description: '源码仓库 URL 或节点本地路径；留空沿用项目本地仓库', trim: true)
    string(name: 'BRANCH', defaultValue: '', description: '分支名（如 main）；指定时从远端获取，留空使用仓库默认分支', trim: true)
    booleanParam(name: 'UPLOAD_DUFS', defaultValue: false, description: '构建并归档成功后上传 DUFS')
    string(name: 'DUFS_URL', defaultValue: '', description: 'DUFS 目标目录完整 URL；开启上传时必填', trim: true)
    string(name: 'DUFS_CREDENTIALS_ID', defaultValue: 'dufs', description: 'Jenkins 用户名密码凭据 ID', trim: true)
    booleanParam(name: 'SEND_DINGTALK', defaultValue: false, description: '构建成功后发送钉钉通知；可独立于 DUFS 开启', trim: true)
    string(name: 'DINGTALK_CREDENTIALS_ID', defaultValue: 'dingtalk-webhook', description: 'Jenkins Secret text 凭据 ID，内容为机器人完整 Webhook', trim: true)
    choice(name: 'ENVIRONMENT', choices: ['test-prod', 'staging', 'release', 'debug'], description: 'TOA: test-prod/release/debug；自助: staging/release')
    choice(name: 'PROJECT', choices: ['toa-pos', 'self-checkout'], description: 'Android application')
    choice(name: 'PRODUCT', choices: ['self_checkout', 'kiosk'], description: 'Used by self-checkout only')
  }
  environment {
    FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
    PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
    PUB_CACHE = 'C:\\Users\\Administrator\\AppData\\Local\\Pub\\Cache'
    GRADLE_USER_HOME = 'C:\\Users\\Administrator\\.gradle'
  }
  stages {
    stage('Checkout') {
      steps {
        deleteDir()
        powershell '''
          $ErrorActionPreference = 'Stop'
          # @include common.ps1
          Assert-DeliveryOptions
          $repo = switch ($env:PROJECT) {
            'toa-pos' { 'D:\\work\\toa-pos-flutter' }
            'self-checkout' { 'D:\\work\\self-checkout' }
            default { throw "Unsupported project: $env:PROJECT" }
          }
          $allowed = @{ 'toa-pos' = @('test-prod', 'release', 'debug'); 'self-checkout' = @('staging', 'release') }
          if ($env:ENVIRONMENT -notin $allowed[$env:PROJECT]) { throw 'Unsupported project/environment pair' }
          Checkout-Source $repo
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
          $sdk = if ($env:PROJECT -eq 'toa-pos') { 'D:\\work\\candao-package\\.jenkins-sdk\\flutter-3.41.9' } else { 'D:\\work\\self-checkout\\.fvm\\flutter_sdk' }
          if (!(Test-Path -LiteralPath "$sdk\\bin\\flutter.bat")) { throw "Flutter SDK missing: $sdk" }
          $androidSdk = 'C:\\Users\\Administrator\\AppData\\Local\\Android\\Sdk'
          if (!(Test-Path -LiteralPath "$androidSdk\\platform-tools\\adb.exe")) { throw "Android SDK missing: $androidSdk" }
          Push-Location source
          try {
            $requiredVersion = (Get-Content -LiteralPath '.fvmrc' -Raw | ConvertFrom-Json).flutter
            $actualVersion = (& git -C $sdk describe --tags --exact-match).Trim()
            if ($LASTEXITCODE -ne 0 -or $actualVersion -ne $requiredVersion) { throw "Flutter SDK mismatch: required $requiredVersion, found $actualVersion" }
            New-Item -ItemType Directory -Force -Path '.fvm' | Out-Null
            New-Item -ItemType Junction -Path '.fvm\\flutter_sdk' -Target $sdk | Out-Null
            if ($env:PROJECT -eq 'toa-pos') {
              $properties = 'android\\gradle.properties'
              $lines = @(Get-Content -LiteralPath $properties | Where-Object { $_ -notmatch '^systemProp[.](http|https)[.]proxy(Host|Port)=' })
              [IO.File]::WriteAllLines((Join-Path (Get-Location).Path $properties), $lines, [Text.UTF8Encoding]::new($false))
              $wrapper = 'android\\gradle\\wrapper\\gradle-wrapper.properties'
              $wrapperLines = @(Get-Content -LiteralPath $wrapper | ForEach-Object {
                if ($_ -match '^distributionUrl=') { 'distributionUrl=https\\://mirrors.aliyun.com/github/releases/gradle/gradle-distributions/v8.14.0/gradle-8.14-all.zip' }
                else { $_ }
              } | Where-Object { $_ -notmatch '^distributionSha256Sum=' })
              $wrapperLines += 'distributionSha256Sum=efe9a3d147d948d7528a9887fa35abcf24ca1a43ad06439996490f77569b02d1'
              [IO.File]::WriteAllLines((Join-Path (Get-Location).Path $wrapper), $wrapperLines, [Text.UTF8Encoding]::new($false))
            }
          } finally { Pop-Location }
        '''
      }
    }
    stage('Build APK') {
      steps {
        dir('source') {
          timeout(time: 60, unit: 'MINUTES') {
          powershell '''
            $ErrorActionPreference = 'Stop'
            $env:ANDROID_HOME = 'C:\\Users\\Administrator\\AppData\\Local\\Android\\Sdk'
            $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
            $flutter = '.\\.fvm\\flutter_sdk\\bin\\flutter.bat'
            $sdkLock = $null
            $lockPath = "D:\\work\\candao-package\\.jenkins-sdk\\${env:PROJECT}-sdk.lock"
            while ($null -eq $sdkLock) {
              try { $sdkLock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
              catch [IO.IOException] { Start-Sleep -Seconds 5 }
            }
            try {
            if ($env:PROJECT -eq 'toa-pos') {
              for ($attempt = 1; $attempt -le 3; $attempt++) {
                & $flutter precache --windows
                if ($LASTEXITCODE -eq 0) { break }
                if ($attempt -lt 3) { Start-Sleep -Seconds 10 }
              }
              if ($LASTEXITCODE -ne 0) { throw 'Flutter SDK artifact download failed after three attempts' }
            }
            & $flutter pub get
            if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }
            $mode = if ($env:ENVIRONMENT -eq 'debug') { '--debug' } else { '--release' }
            $args = @('build', 'apk', $mode)
            if ($env:PROJECT -eq 'toa-pos') {
              $dart = '.\\.fvm\\flutter_sdk\\bin\\cache\\dart-sdk\\bin\\dart.exe'
              $manifest = (& $dart scripts/generate_incident_build_manifest.dart --platform android --abi universal --build-type $env:ENVIRONMENT | Select-Object -Last 1).Trim()
              if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($manifest)) { throw 'Incident build manifest generation failed' }
              $args += "--dart-define=TOA_INCIDENT_BUILD_MANIFEST_B64=$manifest"
              if ($env:ENVIRONMENT -ne 'debug') {
                $channel = if ($env:ENVIRONMENT -eq 'test-prod') { 'test-production' } else { 'production' }
                $configUrl = "https://tappo.oss-cn-hongkong.aliyuncs.com/toa-pos/$channel/android/latest.json"
                $args += "--dart-define=version_config_url=$configUrl"
              }
              if ($env:ENVIRONMENT -eq 'test-prod') { $args += '--dart-define=test_production=true' }
            } else {
              $flavor = if ($env:PRODUCT -eq 'kiosk') { 'kiosk' } else { 'selfCheckout' }
              $productType = if ($env:PRODUCT -eq 'kiosk') { 'kiosk' } else { 'self_checkout' }
              $appEnv = if ($env:ENVIRONMENT -eq 'release') { 'prod' } else { 'staging' }
              $args += @('--flavor', $flavor, "--dart-define=product_type=$productType", "--dart-define=app_env=$appEnv")
            }
            & $flutter @args
            if ($LASTEXITCODE -ne 0) { throw 'Flutter APK build failed' }
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
          $outputs = @(Get-ChildItem -LiteralPath 'source\\build\\app\\outputs\\flutter-apk' -Filter '*.apk' -File -ErrorAction Stop)
          $outputs = @($outputs | Where-Object { $_.LastWriteTime -ge (Get-Date).AddHours(-2) -and $_.Length -gt 0 })
          if ($outputs.Count -ne 1) { throw "Expected one fresh APK, found $($outputs.Count)" }
          New-Item -ItemType Directory -Force -Path artifacts | Out-Null
          $sha = (git -C source rev-parse --short=12 HEAD).Trim()
          $target = "artifacts\\${env:PROJECT}_${env:PRODUCT}_${env:ENVIRONMENT}_${sha}_${env:BUILD_NUMBER}.apk"
          Copy-Item -LiteralPath $outputs[0].FullName -Destination $target
          Get-FileHash -Algorithm SHA256 -LiteralPath $target | Format-List
        '''
        archiveArtifacts artifacts: 'artifacts/*.apk', fingerprint: true
      }
    }
    stage('Upload DUFS') {
      when { expression { params.UPLOAD_DUFS } }
      steps {
        withCredentials([usernamePassword(credentialsId: params.DUFS_CREDENTIALS_ID, usernameVariable: 'DUFS_USER', passwordVariable: 'DUFS_PASSWORD')]) {
          powershell '''
            $ErrorActionPreference = 'Stop'
            # @include common.ps1
            Publish-Artifacts
          '''
        }
        archiveArtifacts artifacts: 'dufs-links.txt'
      }
    }
    stage('Notify DingTalk') {
      when { expression { params.SEND_DINGTALK } }
      steps {
        withCredentials([string(credentialsId: params.DINGTALK_CREDENTIALS_ID, variable: 'DINGTALK_WEBHOOK')]) {
          powershell '''
            $ErrorActionPreference = 'Stop'
            # @include common.ps1
            Send-BuildNotification
          '''
        }
      }
    }
  }
}
