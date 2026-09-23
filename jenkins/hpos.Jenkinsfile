pipeline {
  agent any
  options {
    skipDefaultCheckout(true)
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
    choice(name: 'BUILD_TYPE', choices: ['test-prod', 'pre-prod', 'release', 'debug'], description: 'Application environment and Flutter build mode')
  }
  environment {
    SOURCE_REPO = 'D:\\work\\flutter-hpos'
    FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
    PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
    PUB_CACHE = 'C:\\Users\\Administrator\\AppData\\Local\\Pub\\Cache'
    GRADLE_USER_HOME = 'C:\\Users\\Administrator\\.gradle'
  }
  stages {
    stage('Checkout') {
      steps {
        deleteDir()
        checkout scm
        powershell '''
          $ErrorActionPreference = 'Stop'
          . "$env:WORKSPACE/jenkins/common.ps1"
          Assert-DeliveryOptions
          Checkout-Source $env:SOURCE_REPO
        '''
      }
    }
    stage('Preflight') {
      steps {
        dir('source') {
          timeout(time: 15, unit: 'MINUTES') {
          powershell '''
            $ErrorActionPreference = 'Stop'
            if (!(Get-Command fvm -ErrorAction SilentlyContinue)) { throw 'FVM is not installed on this Jenkins node' }
            $sdk = 'D:\\work\\candao-package\\.jenkins-sdk\\flutter-3.38.9'
            if (!(Test-Path -LiteralPath "$sdk\\bin\\flutter.bat")) { throw "Flutter SDK missing: $sdk" }
            $requiredVersion = (Get-Content -LiteralPath '.fvmrc' -Raw | ConvertFrom-Json).flutter
            $actualVersion = (& git -C $sdk describe --tags --exact-match).Trim()
            if ($LASTEXITCODE -ne 0 -or $actualVersion -ne $requiredVersion) { throw "Flutter SDK mismatch: required $requiredVersion, found $actualVersion" }
            New-Item -ItemType Directory -Force -Path '.fvm' | Out-Null
            New-Item -ItemType Junction -Path '.fvm\\flutter_sdk' -Target $sdk | Out-Null
            if (!(Test-Path -LiteralPath 'pubspec.yaml')) { throw 'pubspec.yaml missing' }
            & .\\.fvm\\flutter_sdk\\bin\\flutter.bat --version
            if ($LASTEXITCODE -ne 0) { throw 'Flutter version check failed' }
          '''
          }
        }
      }
    }
    stage('Build APK') {
      steps {
        dir('source') {
          timeout(time: 60, unit: 'MINUTES') {
          bat 'call .fvm\\flutter_sdk\\bin\\flutter.bat pub get'
          powershell '''
            $ErrorActionPreference = 'Stop'
            $flutter = '.\\.fvm\\flutter_sdk\\bin\\flutter.bat'
            $env:ANDROID_HOME = 'C:\\Users\\Administrator\\AppData\\Local\\Android\\Sdk'
            $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
            if (!(Test-Path -LiteralPath "$env:ANDROID_HOME\\platform-tools\\adb.exe")) { throw 'Android SDK missing' }
            $args = @('build', 'apk', '--verbose')
            switch ($env:BUILD_TYPE) {
              'debug' { $args += '--debug' }
              'test-prod' { $args += @('--release', '--dart-define=test_production=true') }
              'pre-prod' { $args += @('--release', '--dart-define=pre_production=true', '--dart-define=show_ume=true') }
              'release' { $args += '--release' }
              default { throw "Unsupported build type: $env:BUILD_TYPE" }
            }
            & $flutter @args
            if ($LASTEXITCODE -ne 0) { throw 'Flutter APK build failed' }
          '''
          }
        }
      }
    }
    stage('Verify and archive') {
      steps {
        powershell '''
          $ErrorActionPreference = 'Stop'
          $mode = if ($env:BUILD_TYPE -eq 'debug') { 'debug' } else { 'release' }
          $apk = "source\\build\\app\\outputs\\flutter-apk\\app-$mode.apk"
          if (!(Test-Path -LiteralPath $apk)) { throw "APK missing: $apk" }
          $file = Get-Item -LiteralPath $apk
          if ($file.Length -le 0) { throw "APK is empty: $apk" }
          New-Item -ItemType Directory -Force -Path artifacts | Out-Null
          $sha = (git -C source rev-parse --short=12 HEAD).Trim()
          if ($LASTEXITCODE -ne 0) { throw 'Git revision lookup failed' }
          $target = "artifacts\\hpos_${env:BUILD_TYPE}_${sha}_${env:BUILD_NUMBER}.apk"
          Copy-Item -LiteralPath $apk -Destination $target
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
        withCredentials([string(credentialsId: params.DINGTALK_CREDENTIALS_ID, variable: 'DINGTALK_WEBHOOK')]) {
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
