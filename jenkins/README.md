# 本机 Jenkins 打包任务

当前配置了三个 Pipeline：

| Jenkins 任务 | 源码 | 已接入的仅构建配方 |
| --- | --- | --- |
| `HPOS-Android-Package` | `D:\work\flutter-hpos` | Android APK：debug、test-prod、pre-prod、release |
| `Candao-Windows-Package` | `D:\work\toa-meal-pick-up-screen-flutter`、`D:\work\self-checkout`、`D:\work\toa-pos-flutter` | 排队屏 qc/release 双角色安装包；自助买单机 staging/release 安装包；TOA POS test-prod 安装包 |
| `Candao-Android-Package` | `D:\work\self-checkout`、`D:\work\toa-pos-flutter` | 自助买单机 staging APK；TOA POS test-prod APK |

源码从上述本机仓库当前检出的提交复制到 Jenkins 独立工作区。未提交的本机改动不进入构建。每次构建打印 Git SHA；产物带任务号和 SHA 归档，并计算 SHA-256。

TOA POS 开发工作区当前未提交的 `.fvmrc` 与仓库提交不同。Jenkins 以已提交的 `3.41.9` 为准，使用独立 SDK。

这些任务不调用上传、钉钉、TestFlight、Shorebird release/patch 或 OSS latest 更新入口。生产环境的“仅构建”产物仍须检查签名和包内环境后才能发布。部分项目的当前 Android 配置使用 debug 签名，不能直接当正式发布包。

Windows 构建机须具备 Inno Setup 6、Visual Studio Windows 构建工具、FVM 和对应 Flutter SDK。Android 构建还需要 Android SDK/JDK。HPOS 和 TOA POS 分别使用 `.jenkins-sdk/flutter-3.38.9`、`.jenkins-sdk/flutter-3.41.9` 的独立 SDK；自助买单机使用本机项目已安装的 SDK。Pipeline 会核验 SDK Git 标签是否与已提交的 `.fvmrc` 一致。TOA POS 和自助买单机的 Android/Windows 任务按项目共享本地锁，避免并发修改同一 SDK 缓存。换节点时需修改路径。首次拉取 Dart 缓存和依赖可能耗时。排队屏构建还会下载 NuGet、WebView2 和 .NET 安装器（若缓存不存在）。

尚未接入 `TAPPO` 与 `tappo_phone`：本机没有这两个源码目录，仓库地址待提供。iOS IPA 需要 macOS Jenkins 节点和签名资料。高层发布脚本有外部副作用，发布、上传、通知需另建凭据和独立阶段。

Pipeline 源文件在本目录。Jenkins 任务当前保存的是这些文件的内联副本；修改文件后运行 `sync-jobs.ps1` 同步配置。脚本从当前进程的 `JENKINS_USER`、`JENKINS_API_TOKEN` 环境变量取凭据，不写入仓库。首次新建任务时 Jenkins 会在第一次运行后注册 Pipeline 参数。
