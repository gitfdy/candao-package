pipeline {
  agent any
  options {
    skipDefaultCheckout(true)
    disableConcurrentBuilds()
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '20'))
  }
  environment {
    PROJECT = 'self-checkout'
    DUFS_URL = "${params.PRODUCT == 'kiosk' ? 'http://192.168.225.46:5000/dufs/Kiosk-Windows' : 'http://192.168.225.46:5000/dufs/Self-Checkout-Windows'}"
    DUFS_CREDENTIALS_ID = 'dufs'
    DINGTALK_CREDENTIALS_ID = 'dingtalk-webhook'
    FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
    PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
    PUB_CACHE = 'C:\\Users\\Administrator\\AppData\\Local\\Pub\\Cache'
  }
  parameters {
    choice(name: 'REPOSITORY_URL', choices: ['https://git.can-dao.com/flutter-business/self-checkout.git'], description: '源码仓库')
    activeChoice(name: 'BRANCH', choiceType: 'PT_SINGLE_SELECT', filterable: true, filterLength: 1, description: 'GitLab 远端分支，可搜索；默认 main', script: groovyScript(script: [sandbox: false, script: '''
import jenkins.model.Jenkins
import hudson.security.ACL
import com.cloudbees.plugins.credentials.CredentialsProvider
import com.cloudbees.plugins.credentials.common.StandardUsernamePasswordCredentials
try {
  def job = Jenkins.get().getItemByFullName('TOA-KIOSK-WINDOWS')
  def credential = CredentialsProvider.lookupCredentials(StandardUsernamePasswordCredentials.class, job, ACL.SYSTEM, []).find { it.id == 'candao-git-new' }
  if (!credential) return ['Git credential unavailable:disabled']
  def url = 'https://git.can-dao.com/flutter-business/self-checkout.git'
  def client = org.jenkinsci.plugins.gitclient.Git.with(hudson.model.TaskListener.NULL, new hudson.EnvVars(System.getenv())).using('git').getClient()
  client.addCredentials(url, credential)
  def branches = client.getRemoteReferences(url, 'refs/heads/*', true, false).keySet().collect { it.replaceFirst('^refs/heads/', '') }.sort()
  return branches ? branches.collect { it == 'main' ? it + ':selected' : it } : ['No remote branches:disabled']
} catch (Exception ignored) {
  return ['Unable to read remote branches:disabled']
}
'''], fallbackScript: [sandbox: true, script: "return ['Unable to read remote branches:disabled']"]))
    choice(name: 'PRODUCT', choices: ['kiosk', 'self_checkout'], description: '产品：Kiosk / 自助收银')
    choice(name: 'ENVIRONMENT', choices: ['staging', 'test-prod', 'release', 'debug'], description: '构建环境，与分支独立；release 为生产，prod 是其别名')
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
          if ($env:ENVIRONMENT -notin @('staging', 'test-prod', 'release', 'debug')) { throw 'Unsupported environment' }
        '''
        script {
          if (params.REPOSITORY_URL != 'https://git.can-dao.com/flutter-business/self-checkout.git') { error('Invalid repository') }
          if (!params.BRANCH || !(params.BRANCH ==~ /[A-Za-z0-9][A-Za-z0-9._\/-]*/) || params.BRANCH.contains('..')) { error('Select a valid branch') }
          dir('source') {
            checkout([$class: 'GitSCM', branches: [[name: "refs/heads/${params.BRANCH}"]], userRemoteConfigs: [[url: params.REPOSITORY_URL, credentialsId: 'candao-git-new']], extensions: []])
          }
          dir('octopus_payment_flutter') {
            checkout([$class: 'GitSCM', branches: [[name: 'refs/heads/v3.8.1-TA']], userRemoteConfigs: [[url: 'https://git.can-dao.com/flutter-business/octopus_payment_flutter.git', credentialsId: 'candao-git-new']], extensions: []])
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
            $sdk = switch ($env:PROJECT) {
              'self-checkout' { 'D:\\work\\self-checkout\\.fvm\\flutter_sdk' }
              'toa-pos' { 'D:\\work\\candao-package\\.jenkins-sdk\\flutter-3.41.9' }
            }
            if (!(Test-Path -LiteralPath "$sdk\\bin\\flutter.bat")) { throw "Flutter SDK missing: $sdk" }
            Push-Location source
            try {
              $actualVersion = (& git -C $sdk describe --tags --exact-match).Trim()
              if ($LASTEXITCODE -ne 0) { throw 'Cannot identify installed Flutter SDK version' }
              if (Test-Path -LiteralPath '.fvmrc') {
                $requiredVersion = (Get-Content -LiteralPath '.fvmrc' -Raw | ConvertFrom-Json).flutter
                if ($actualVersion -ne $requiredVersion) { throw "Flutter SDK mismatch: required $requiredVersion, found $actualVersion" }
              } else {
                # Older self-checkout branches omit FVM metadata; pin the configured node SDK for fvm flutter.
                @{ flutter = $actualVersion } | ConvertTo-Json | Set-Content -LiteralPath '.fvmrc' -Encoding UTF8
              }
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
          foreach ($file in $files) {
            if ($file.Length -le 0) { throw "Empty installer: $($file.FullName)" }
            $target = Join-Path artifacts $file.Name
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
