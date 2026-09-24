pipeline {
  agent any
  options {
    skipDefaultCheckout(true)
    disableConcurrentBuilds()
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '20'))
  }
  parameters {
    activeChoice(name: 'BRANCH', choiceType: 'PT_SINGLE_SELECT', filterable: true, filterLength: 1, description: 'GitLab 远端分支，可搜索；默认 devlop_qc', script: groovyScript(script: [sandbox: false, script: '''
import jenkins.model.Jenkins
import hudson.security.ACL
import com.cloudbees.plugins.credentials.CredentialsProvider
import com.cloudbees.plugins.credentials.common.StandardUsernamePasswordCredentials
try {
  def credentialScope = Jenkins.get()
  def credential = CredentialsProvider.lookupCredentials(StandardUsernamePasswordCredentials.class, credentialScope, ACL.SYSTEM, []).find { it.id == 'candao-git-new' }
  if (!credential) return ['Git credential unavailable:disabled']
  def url = 'https://git.can-dao.com/flutter-business/tappo_phone.git'
  def client = org.jenkinsci.plugins.gitclient.Git.with(hudson.model.TaskListener.NULL, new hudson.EnvVars(System.getenv())).using('git').getClient()
  client.addCredentials(url, credential)
  def branches = client.getRemoteReferences(url, 'refs/heads/*', true, false).keySet().collect { it.replaceFirst('^refs/heads/', '') }.sort()
  return branches ? branches.collect { it == 'devlop_qc' ? it + ':selected' : it } : ['No remote branches:disabled']
} catch (Exception ignored) {
  return ['Unable to read remote branches:disabled']
}
'''], fallbackScript: [sandbox: true, script: "return ['Unable to read remote branches:disabled']"]))
    choice(name: 'PACKAGE_FORMAT', choices: ['apk', 'aab'], description: 'APK 可直接安装；AAB 用于商店分发。默认 APK')
    choice(name: 'ENVIRONMENT', choices: ['qc', 'prod'], description: '业务环境，与分支独立；统一使用 Release 编译')
    credentials(name: 'SIGNING_KEY', credentialType: 'org.jenkinsci.plugins.plaincredentials.impl.FileCredentialsImpl', defaultValue: '', required: false, description: '选择已上传的签名密钥；不选则内部测试签名。Tappo Phone AAB 必选原 Google Play 上传密钥')
    string(name: 'VERSION_CODE', defaultValue: '', description: '可选 Android versionCode；留空沿用源码，上架时必须高于已发布版本', trim: true)
    booleanParam(name: 'UPLOAD_DUFS', defaultValue: false, description: '构建并验证成功后上传 DUFS')
    booleanParam(name: 'SEND_DINGTALK', defaultValue: false, description: '发送钉钉通知；失败不影响构建成功')
  }
  environment {
    JAVA_HOME = 'C:\\Program Files\\Java\\jdk-21.0.12.1'
    PROJECT = 'tappo_phone'
    SOURCE_REPO = 'https://git.can-dao.com/flutter-business/tappo_phone.git'
    DUFS_URL = 'http://192.168.225.46:5000/dufs/TAPPO_PHONE'
    DUFS_CREDENTIALS_ID = 'dufs'
    DINGTALK_CREDENTIALS_ID = 'dingtalk-webhook'
    FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
    PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
    PUB_CACHE = 'C:\\Users\\Administrator\\AppData\\Local\\Pub\\Cache'
  }
  stages {
    stage('Checkout') {
      steps {
        deleteDir()
        checkout scm
        script {
          if (!params.BRANCH || !(params.BRANCH ==~ /[A-Za-z0-9][A-Za-z0-9._\/-]*/) || params.BRANCH.contains('..')) { error('Select a valid remote branch') }
          dir('source') {
            checkout([$class: 'GitSCM', branches: [[name: "refs/heads/${params.BRANCH}"]], userRemoteConfigs: [[url: env.SOURCE_REPO, credentialsId: 'candao-git-new']], extensions: []])
          }
        }
      }
    }
    stage('Build Android and verify signature') {
      steps {
        timeout(time: 60, unit: 'MINUTES') {
          script {
            def build = {
              powershell '''
                $ErrorActionPreference = 'Stop'
                $env:GRADLE_USER_HOME = "$env:WORKSPACE/source/.gradle-home"
                . "$env:WORKSPACE/jenkins/tappo-android.ps1"
                Invoke-TappoAndroidBuild
              '''
            }
            if (params.SIGNING_KEY) {
              if (!(params.SIGNING_KEY ==~ /[A-Za-z0-9][A-Za-z0-9._-]*/)) { error('Invalid signing credential ID') }
              withCredentials([
                file(credentialsId: params.SIGNING_KEY, variable: 'TAPPO_PHONE_KEYSTORE_PATH'),
                usernamePassword(credentialsId: "${params.SIGNING_KEY}-passwords", usernameVariable: 'TAPPO_PHONE_KEY_ALIAS', passwordVariable: 'TAPPO_PHONE_STORE_PASSWORD'),
                string(credentialsId: "${params.SIGNING_KEY}-key-password", variable: 'TAPPO_PHONE_KEY_PASSWORD'),
                string(credentialsId: "${params.SIGNING_KEY}-sha256", variable: 'TAPPO_PHONE_UPLOAD_SHA256')
              ]) { build() }
            } else {
              if (env.PROJECT == 'tappo_phone' && params.PACKAGE_FORMAT == 'aab') { error('Select the existing Google Play upload key for Tappo Phone AAB') }
              build()
            }
          }
        }
      }
    }
    stage('Verify and archive') {
      steps { archiveArtifacts artifacts: 'artifacts/*', fingerprint: true }
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
