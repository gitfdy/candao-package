pipeline {
  agent any
  options {
    skipDefaultCheckout(true)
    disableConcurrentBuilds()
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '20'))
  }
  environment {
    PROJECT = 'toa-pos'
    DUFS_URL = 'http://192.168.225.46:5000/dufs/TOA-POS-Windows'
    DUFS_CREDENTIALS_ID = 'dufs'
    DINGTALK_CREDENTIALS_ID = 'dingtalk-webhook'
    FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
    PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
    PUB_CACHE = 'C:\\Users\\Administrator\\AppData\\Local\\Pub\\Cache'
  }
  parameters {
    choice(name: 'REPOSITORY_URL', choices: ['https://git.can-dao.com/flutter-business/toa-pos-flutter.git'], description: '源码仓库')
    activeChoice(name: 'BRANCH', choiceType: 'PT_SINGLE_SELECT', filterable: true, filterLength: 1, description: 'GitLab 远端分支，可搜索；默认 devlop_qc', script: groovyScript(script: [sandbox: false, script: '''
import jenkins.model.Jenkins
import hudson.security.ACL
import com.cloudbees.plugins.credentials.CredentialsProvider
import com.cloudbees.plugins.credentials.common.StandardUsernamePasswordCredentials
try {
  def credentialScope = Jenkins.get()
  def credential = CredentialsProvider.lookupCredentials(StandardUsernamePasswordCredentials.class, credentialScope, ACL.SYSTEM, []).find { it.id == 'candao-git-new' }
  if (!credential) return ['Git credential unavailable:disabled']
  def url = 'https://git.can-dao.com/flutter-business/toa-pos-flutter.git'
  def client = org.jenkinsci.plugins.gitclient.Git.with(hudson.model.TaskListener.NULL, new hudson.EnvVars(System.getenv())).using('git').getClient()
  client.addCredentials(url, credential)
  def branches = client.getRemoteReferences(url, 'refs/heads/*', true, false).keySet().collect { it.replaceFirst('^refs/heads/', '') }.sort()
  return branches ? branches.collect { it == 'devlop_qc' ? it + ':selected' : it } : ['No remote branches:disabled']
} catch (Exception ignored) {
  return ['Unable to read remote branches:disabled']
}
'''], fallbackScript: [sandbox: true, script: "return ['Unable to read remote branches:disabled']"]))
    choice(name: 'ENVIRONMENT', choices: ['test-prod', 'pre-prod', 'release', 'debug', 'release-debug'], description: '测试 / 预生产 / 生产 / 调试 / 生产调试；与分支独立选择')
    booleanParam(name: 'ENABLE_INCIDENT_UPLOAD', defaultValue: false, description: '启用 Incident 故障上报；需管理员配置 TOA_INCIDENT_API_BASE_URL，且所选分支和环境支持')
    booleanParam(name: 'UPLOAD_DUFS', defaultValue: false, description: '构建并归档成功后上传 DUFS')
    booleanParam(name: 'SEND_DINGTALK', defaultValue: false, description: '构建成功后发送钉钉通知')
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
          if ($env:ENVIRONMENT -notin @('test-prod', 'pre-prod', 'release', 'debug', 'release-debug')) { throw 'Unsupported TOA build environment' }
        '''
        script {
          if (params.REPOSITORY_URL != 'https://git.can-dao.com/flutter-business/toa-pos-flutter.git') {
            error('Select the configured TOA repository')
          }
          if (env.PROJECT == 'toa-pos') {
            def toaCheckout = load 'jenkins/checkout-toa.groovy'
            toaCheckout.call(params.REPOSITORY_URL, params.BRANCH)
          }
        }
      }
    }
    stage('Preflight') {
      steps {
        powershell '''
          $ErrorActionPreference = 'Stop'
          if (!(Test-Path -LiteralPath 'C:\\Program Files (x86)\\Inno Setup 6\\ISCC.exe')) { throw 'Inno Setup 6 is missing' }
          if ($env:PROJECT -ne 'queue-screen') {
            if (!(Get-Command fvm -ErrorAction SilentlyContinue)) { throw 'FVM is missing' }
            Push-Location source
            try {
              $requiredVersion = if (Test-Path -LiteralPath '.fvmrc') {
                (Get-Content -LiteralPath '.fvmrc' -Raw | ConvertFrom-Json).flutter
              } else { '3.27.2' }
              if ($requiredVersion -notmatch '^[0-9]+[.][0-9]+[.][0-9]+$') { throw 'Invalid Flutter version in .fvmrc' }
              $sdk = "D:\\work\\candao-package\\.jenkins-sdk\\flutter-$requiredVersion"
              if (!(Test-Path -LiteralPath "$sdk\\bin\\flutter.bat")) { throw "Install the required CI Flutter SDK: $sdk" }
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
      environment {
        // The TOA runner contains UTF-8 source; Windows nodes may use code page 936.
        CL = '/utf-8'
        // CMake downloads do not use the Windows desktop or Git proxy settings.
        HTTPS_PROXY = 'http://127.0.0.1:7897'
        HTTP_PROXY = 'http://127.0.0.1:7897'
        NO_PROXY = 'localhost,127.0.0.1,192.168.220.95,git.can-dao.com,pub.flutter-io.cn,storage.flutter-io.cn'
      }
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
                . "$env:WORKSPACE/jenkins/prepare-toa-build.ps1"
                Prepare-ToaBuild (Get-Location).Path $env:ENVIRONMENT $env:ENABLE_INCIDENT_UPLOAD
                & cmd.exe /d /c "scripts\\build_windows.bat --type $env:ENVIRONMENT --proxy none --local true"
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
        catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE', catchInterruptions: false, message: 'DingTalk notification failed; package result is unchanged') {
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
}
