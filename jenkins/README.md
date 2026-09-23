# 本机 Jenkins 打包任务

当前配置了三个 Pipeline：

| Jenkins 任务 | 源码 | 已接入的仅构建配方 |
| --- | --- | --- |
| `HPOS-Android-Package` | `D:\work\flutter-hpos` | Android APK：debug、test-prod、pre-prod、release |
| `Candao-Windows-Package` | `D:\work\toa-meal-pick-up-screen-flutter`、`D:\work\self-checkout`、`D:\work\toa-pos-flutter` | 排队屏 qc/release 双角色安装包；自助买单机 staging/release 安装包；TOA POS test-prod/release 安装包 |
| `Candao-Android-Package` | `D:\work\self-checkout`、`D:\work\toa-pos-flutter` | 自助买单机 staging/release APK；TOA POS test-prod/release/debug APK |

默认从上述本机仓库当前检出的提交复制到 Jenkins 独立工作区；也可指定仓库与分支。未提交的本机改动不进入构建。每次构建打印 Git SHA；产物带任务号和 SHA 归档，并计算 SHA-256。

TOA POS 开发工作区当前未提交的 `.fvmrc` 与仓库提交不同。Jenkins 以已提交的 `3.41.9` 为准，使用独立 SDK。

这些任务默认只构建；可独立开启 DUFS 上传与钉钉通知。不调用 TestFlight、Shorebird release/patch 或 OSS latest 更新入口。生产环境的“仅构建”产物仍须检查签名和包内环境后才能发布。部分项目的当前 Android 配置使用 debug 签名，不能直接当正式发布包。

Windows 构建机须具备 Inno Setup 6、Visual Studio Windows 构建工具、FVM 和对应 Flutter SDK。Android 构建还需要 Android SDK/JDK。HPOS 和 TOA POS 分别使用 `.jenkins-sdk/flutter-3.38.9`、`.jenkins-sdk/flutter-3.41.9` 的独立 SDK；自助买单机使用本机项目已安装的 SDK。Pipeline 会核验 SDK Git 标签是否与已提交的 `.fvmrc` 一致。TOA POS 和自助买单机的 Android/Windows 任务按项目共享本地锁，避免并发修改同一 SDK 缓存。换节点时需修改路径。首次拉取 Dart 缓存和依赖可能耗时。排队屏构建还会下载 NuGet、WebView2 和 .NET 安装器（若缓存不存在）。

尚未接入 `TAPPO` 与 `tappo_phone`：本机没有这两个源码目录，仓库地址待提供。iOS IPA 需要 macOS Jenkins 节点和签名资料。高层发布脚本有外部副作用，DUFS 与钉钉使用独立凭据和阶段。

三个 Jenkins 任务使用 **Pipeline script from SCM**，直接从 `https://github.com/gitfdy/candao-package.git` 的 `main` 分支读取 `jenkins/*.Jenkinsfile`。构建开始时通过 `checkout scm` 获取辅助脚本。修改提交并推送后，下一次构建会从远端读取，无需先手动更新 `D:\work\candao-package`。增加或修改参数时仍需运行同步脚本，才能在首次构建前更新参数表单。

Windows 的 Jenkins 服务以 LocalSystem 运行。此账号的 Git 已针对 `https://github.com` 配置现有本机代理 `http://127.0.0.1:7897`；不修改系统代理或 TLS 校验。代理进程须可用，否则远端检出会失败。同步脚本默认使用当前仓库的 `origin`，可通过 `-RepositoryUrl` 显式覆盖；不会把开发者远端 URL 内的 HTTP 凭据复制到 Jenkins。Jenkins 登录凭据从当前进程的 `JENKINS_USER`、`JENKINS_API_TOKEN` 读取，不写入仓库。

## 可配置打包与分发

三个任务均支持：

- `REPOSITORY_URL`：源码 Git URL 或构建节点本地路径。留空沿用上表本地仓库。
- `BRANCH`：分支名，例如 `main`、`feature/example`。填写后获取该分支；仓库地址留空时，从本地仓库的 `origin` 获取最新分支。两项都留空保持原有行为，复制本地仓库当前已提交版本。填写 URL、分支留空则使用该仓库默认分支。私有 Git 认证使用构建节点现有配置，不要在 URL 内填写密码或 Token。
- HPOS 的环境使用 `BUILD_TYPE`；另外两个任务使用 `ENVIRONMENT`。不支持的项目／环境组合在下载和构建前报错。
- `UPLOAD_DUFS`：默认关闭。开启时填写 `DUFS_URL` 目标目录和 `DUFS_CREDENTIALS_ID`，后者引用 Jenkins 的 Username with password 凭据（默认 ID `dufs`）。目标目录须已存在且可写。先归档，再上传；回读 SHA-256 一致才记为上传成功。
- `SEND_DINGTALK`：默认关闭。独立控制成功通知，可在不上传时发送 Jenkins 产物入口。`DINGTALK_CREDENTIALS_ID` 引用 Secret text 凭据（默认 ID `dingtalk-webhook`），内容为机器人完整 Webhook。机器人需允许关键词 `Candao` 或构建节点 IP；当前不支持机器人加签。上传开启但失败时任务失败，不发送成功通知。

新增仅构建环境：TOA Android 支持 `test-prod/release/debug`，自助 Android 支持 `staging/release`；TOA Windows 支持 `test-prod/release`。其余 Windows 环境保持原范围。`release` 不触发 OSS、Shorebird 或自动更新元数据发布。分支仍须兼容本机 SDK 和构建脚本；自助项目的 `octopus_payment_flutter` 依赖继续取节点本地仓库已提交版本。

`common.ps1` 随 Jenkinsfile 一起从 Git 检出。`sync-jobs.ps1` 配置三个任务的 Git SCM、Jenkinsfile 路径与参数；同步会立即注册参数，无需先跑一次构建。保留现有任务的其他配置。

在另一台 Windows 构建机的仓库目录更新后执行（当前 PowerShell 会话需已设置 `JENKINS_USER`、`JENKINS_API_TOKEN`）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\jenkins\sync-jobs.ps1
```

需要覆盖脚本仓库或分支时，可传入 `-RepositoryUrl`、`-Branch` 和可选的 `-CredentialsId`（Jenkins Git 凭据 ID），例如 `-RepositoryUrl https://github.com/gitfdy/candao-package.git -Branch main`。不要把密码或 Token 写在 URL 中。同步只更新配置，不触发构建、上传或通知。刷新 Jenkins 任务页面，进入“Build with Parameters”检查新字段。

离线验证，不访问外部服务：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\jenkins\test-options.ps1
# 仅输出配置 XML 供审阅；不要求 Jenkins 凭据
powershell -NoProfile -ExecutionPolicy Bypass -File .\jenkins\sync-jobs.ps1 -OutputDirectory "$env:TEMP\candao-jenkins-preview"
```
