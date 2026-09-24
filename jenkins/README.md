# 本机 Jenkins 打包任务

当前配置了四个 Pipeline：

| Jenkins 任务 | 源码 | 已接入的仅构建配方 |
| --- | --- | --- |
| `HPOS-Android-Package` | `D:\work\flutter-hpos` | Android APK：debug、test-prod、pre-prod、release |
| `Candao-Windows-Package` | `D:\work\toa-meal-pick-up-screen-flutter`、`D:\work\self-checkout`、`D:\work\toa-pos-flutter` | 排队屏 qc/release 双角色安装包；自助买单机 staging/release 安装包；TOA POS test-prod 安装包 |
| `TOA-POS-Windows-Package` | `D:\work\toa-pos-flutter` 的 `devlop_qc` | 独立 TOA POS QC 入口，仅 test-prod；不会生成排队机安装包 |
| `Candao-Android-Package` | `D:\work\self-checkout`、`D:\work\toa-pos-flutter` | 自助买单机 staging/release APK；TOA POS test-prod/release/debug APK |

默认从上述本机仓库当前检出的提交复制到 Jenkins 独立工作区；也可指定仓库与分支。未提交的本机改动不进入构建。每次构建打印 Git SHA；产物带任务号和 SHA 归档，并计算 SHA-256。

TOA POS Windows 使用独立 Flutter 3.41.9 SDK。源码提交含 `.fvmrc` 时严格核对版本；旧分支未提交该文件时，使用已配置的 3.41.9 并记录日志，不读取开发工作区的未提交配置。

这些任务默认只构建；可独立开启 DUFS 上传与钉钉通知。不调用 TestFlight、Shorebird release/patch 或 OSS latest 更新入口。生产环境的“仅构建”产物仍须检查签名和包内环境后才能发布。部分项目的当前 Android 配置使用 debug 签名，不能直接当正式发布包。

Windows 构建机须具备 Inno Setup 6、Visual Studio Windows 构建工具、FVM 和对应 Flutter SDK。Android 构建还需要 Android SDK/JDK。HPOS 和 TOA POS 分别使用 `.jenkins-sdk/flutter-3.38.9`、`.jenkins-sdk/flutter-3.41.9` 的独立 SDK；自助买单机使用本机项目已安装的 SDK。Pipeline 会核验 SDK Git 标签是否与已提交的 `.fvmrc` 一致。TOA POS 和自助买单机的 Android/Windows 任务按项目共享本地锁，避免并发修改同一 SDK 缓存。换节点时需修改路径。首次拉取 Dart 缓存和依赖可能耗时。排队屏构建还会下载 NuGet、WebView2 和 .NET 安装器（若缓存不存在）。

尚未接入 `TAPPO` 与 `tappo_phone`：本机没有这两个源码目录，仓库地址待提供。iOS IPA 需要 macOS Jenkins 节点和签名资料。高层发布脚本有外部副作用，DUFS 与钉钉使用独立凭据和阶段。

四个 Jenkins 任务使用 **Pipeline script from SCM**，直接从 `https://github.com/gitfdy/candao-package.git` 的 `main` 分支读取 `jenkins/*.Jenkinsfile`。构建开始时通过 `checkout scm` 获取辅助脚本。修改提交并推送后，下一次构建会从远端读取，无需先手动更新 `D:\work\candao-package`。增加或修改参数时仍需运行同步脚本，才能在首次构建前更新参数表单。

Windows 的 Jenkins 服务以 LocalSystem 运行。此账号的 Git 已针对 `https://github.com` 配置现有本机代理 `http://127.0.0.1:7897`；不修改系统代理或 TLS 校验。代理进程须可用，否则远端检出会失败。同步脚本默认使用当前仓库的 `origin`，可通过 `-RepositoryUrl` 显式覆盖；不会把开发者远端 URL 内的 HTTP 凭据复制到 Jenkins。Jenkins 登录凭据从当前进程的 `JENKINS_USER`、`JENKINS_API_TOKEN` 读取，不写入仓库。

## 可配置打包与分发

四个任务均支持：

- `REPOSITORY_URL`：TOA 仅支持公司 HTTPS Git URL，留空默认 TOA 远端地址；其他项目支持 Git URL 或节点本地路径，留空沿用上表本地仓库。
- `BRANCH`：TOA 留空默认 `devlop_qc`，通过 Jenkins 凭据 `candao-git-new` 拉取远端分支。其他项目填写分支时，地址留空则读取本地仓库 `origin`；两项均空则复制本地已提交版本，指定 URL 但分支留空则使用仓库默认分支。其他项目认证沿用节点配置。不要在 URL 中填写密码或 Token。
- HPOS 的环境使用 `BUILD_TYPE`；另外两个任务使用 `ENVIRONMENT`。不支持的项目／环境组合在下载和构建前报错。
- `UPLOAD_DUFS`：默认关闭。TOA Windows 已预填 `DUFS_URL=http://192.168.225.46:5000/dufs/TOA-POS-Windows`（取自 `devlop_qc` 构建脚本），其他任务开启时填写目标目录。流水线固定引用 Jenkins 的 Username with password 凭据 `dufs`，不再要求在构建表单填写凭据 ID。目标目录须已存在且可写。先归档，再上传；回读 SHA-256 一致才记为上传成功。
- `SEND_DINGTALK`：默认关闭。独立控制成功通知，可在不上传时发送 Jenkins 产物入口。流水线固定引用 Secret text 凭据 `dingtalk-webhook`，不再显示凭据 ID 输入框，内容为机器人完整 Webhook。消息包含原 TOA 机器人要求的关键词 `push`，并保留 `Candao`；机器人需允许对应关键词或构建节点 IP；当前不支持机器人加签。上传开启但失败时任务失败，不发送成功通知。

新增仅构建环境：TOA Android 支持 `test-prod/release/debug`，自助 Android 支持 `staging/release`；TOA Windows 仅支持 `test-prod`。其余 Windows 环境保持原范围。`release` 不触发 OSS、Shorebird 或自动更新元数据发布。分支仍须兼容本机 SDK 和构建脚本；自助项目的 `octopus_payment_flutter` 依赖继续取节点本地仓库已提交版本。

`common.ps1` 随 Jenkinsfile 一起从 Git 检出。`sync-jobs.ps1` 配置四个任务的 Git SCM、Jenkinsfile 路径与参数；同步会立即注册参数，无需先跑一次构建。保留现有任务的其他配置。

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

## TOA POS Windows 试跑

进入独立任务 `TOA-POS-Windows-Package` → Build with Parameters。该入口复用 Windows 流水线，项目固定为 `toa-pos`，环境固定为 `test-prod`；不会与排队机的历史产物混在一起。

- 对应仓库：`https://git.can-dao.com/flutter-business/toa-pos-flutter.git`。
- QC 分支实际名为 `devlop_qc`，远端不存在名为 `qc` 的分支。Git 分支名与脚本的 `--type test-prod` 是不同参数。
- 默认 `REPOSITORY_URL=https://git.can-dao.com/flutter-business/toa-pos-flutter.git`、`BRANCH=devlop_qc`。每次清理 Jenkins 工作区后，从远端检出到 `source`，不读取 Windows 开发仓库。TOA 的地址或分支留空时，也使用上述默认值。
- 八达通依赖从 `https://git.can-dao.com/flutter-business/octopus_payment_flutter.git` 的 `main` 分支检出到工作区同级 `octopus_payment_flutter`。日志记录两个仓库的提交 SHA。Android TOA 复用同一检出逻辑。
- 首次使用：在 Jenkins → Manage Jenkins → Credentials 添加 Username with password 凭据，ID 为 `candao-git-new`，账号和密码或令牌需有这两个仓库的只读权限。凭据只用于公司 HTTPS Git 主机；认证失败停止，不回退到本地仓库。
- 旧任务表单如果仍保存本地路径，须同步配置或手动改填远端 URL；TOA 会拒绝本地地址。同步配置不触发构建。
- 本次隔离应用源码和八达通依赖；Flutter SDK、Pub 缓存仍沿用节点已有工具链。其他项目的本地检出流程保持兼容。
- `UPLOAD_DUFS=false`、`SEND_DINGTALK=false` 默认保持关闭；`PRODUCT` 对 TOA 无效。

用户提供的打包契约文档基于 `feature/flutter-native-migration-followup@eb7f9024`，与 QC 分支不同；本入口按实际 QC 脚本运行 `build_windows.bat --type test-prod --proxy none --local true`。当前仅支持该无发布的构建类型，避免新版脚本的 `release` 即使 local=true 仍调用 Shorebird。

构建成功后在此独立任务的 Artifacts 下载 TOA POS EXE；原 `Candao-Windows-Package` 的排队机历史产物保留。

## 手持 POS 构建表单

HPOS 固定使用公司远端 `flutter-hpos.git`，凭据为 `candao-git-new`。表单仅显示 `BRANCH`、`BUILD_TYPE`、`UPLOAD_DUFS`、`SEND_DINGTALK`；两个分发开关默认关闭。DUFS 目录固定为原脚本的 `http://192.168.225.46:5000/dufs/HANDHELP_POS`。上传和通知仍需管理员分别配置 `dufs`（用户名密码）及 `dingtalk-webhook`（Secret text）。

分支使用 Active Choices（`uno-choice`）插件，在打开参数页时通过 Jenkins Git 客户端读取远端全部分支，支持搜索，默认选择 `devlop_qc`。认证或网络失败时显示禁用的错误选项，不回退到开发目录。分支脚本固定仓库和凭据，不接受页面传入的 URL，也不输出密钥。首次同步或修改分支脚本后，管理员须在 In-process Script Approval 审核并批准这段精确脚本；无需开放通用 Groovy 权限。

只同步此任务配置（不编译、不上传、不通知）：`./jenkins/sync-jobs.ps1 -JobName HPOS-Android-Package`。不要对用户重命名过的其他任务盲目执行全量同步。

## TOA Windows 精简表单

现有任务 `TOA-POS-Windows` 从远端 `main` 读取 `jenkins/toa-windows.Jenkinsfile`。仓库使用下拉，当前只列已确认的 TOA 仓库；分支使用 Active Choices 实时读取该仓库，默认 `devlop_qc`。构建环境保持 `test-prod`，固定项目及 DUFS 地址不再出现在表单。上传、钉钉通知保留独立开关，默认关闭，继续引用 Jenkins 的 `dufs`、`dingtalk-webhook`。

只同步该任务：`./jenkins/sync-jobs.ps1 -JobName TOA-POS-Windows`。首次同步后审核批准分支查询脚本。此修改不解决此前 QC 源码与 Flutter/八达通依赖的编译兼容问题。

TOA 专用入口现开放 `test-prod`（测试）、`pre-prod`（预生产）、`release`（生产）、`debug`、`release-debug`，与 Git 分支独立选择。构建只在 Jenkins 临时源码中适配原 BAT，保留各分支的安装器逻辑；已识别的新版 release 跳转改为普通 Flutter 编译，不执行 Shorebird release。仍传入 `--local true`，分发仅由流水线两个开关控制。

若所选源码未实现环境参数、已删除对应 Dart 环境入口，或出现不认识的发布入口，则明确失败，不静默改环境。此调整不承诺任意历史分支都能成功编译，也不恢复应用源码已删除的预生产配置。
