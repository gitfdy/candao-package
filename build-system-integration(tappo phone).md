# 移动端打包脚本解析与打包系统接入说明

> 核查日期：2026-09-23。源码基线：`38c3c6e618f3e8c922188cf584373c5a17f2a1dd`。
> 本文描述当前脚本的真实行为；“建议”均为未来系统设计，不代表已实现。本次未执行打包、上传、通知或热更新发布。
> 当前工作区另有未跟踪的 iOS Fastlane README，未修改；以脚本和应用代码为事实来源，不沿用旧文档的结论。

## 1. 接入结论

项目是 Flutter Melos/pub workspace，App 位于 `apps/mobile`。Android、iOS 分别使用 Fastlane；没有统一任务接口，也没有结构化结果输出。打包系统可复用现有 lane，但必须逐阶段判定构建、分发、通知结果，不能把 Fastlane 退出码为 0 当作“全部发布成功”。

最重要的边界：

- `flavor=qc|prod` 是 Dart 编译参数，不是原生 Android productFlavor 或 Xcode scheme。
- debug/release 编译模式、QC/生产环境、office/store 更新渠道、Flutter/Shorebird 引擎是四个不同维度。
- 普通 Flutter release 包不能因为包含 `shorebird.yaml` 就获得 Shorebird 热更新能力。
- 当前生产 APK lane 自动上传 OSS；只有 QC APK lane 调用 DUFS。生产 APK 上传 DUFS 的历史操作不属于当前 lane 能力。
- AAB lane 不上传 Google Play；Shorebird AAB lane 虽不上传商店，仍会向 Shorebird 上传基线。
- iOS `release` 上传 TestFlight，不等待 Apple 处理完成，不自动提交 App Store 审核。
- 所有公共构建 lane 的 setup 都会执行 `flutter clean`，`build/outputs` 不是长期存储位置。

## 2. 文件与职责

本文命令以本机路径为例，系统接入时必须根据 checkout 根目录动态拼接，不能硬编码开发者主目录。

| 文件 | 职责 |
|---|---|
| [Android Fastfile](/Users/dylan/Desktop/candao/tappo_phone/apps/mobile/android/fastlane/Fastfile) | APK/AAB、Shorebird、DUFS/OSS、钉钉编排 |
| [Android Appfile](/Users/dylan/Desktop/candao/tappo_phone/apps/mobile/android/fastlane/Appfile) | 包名与 Google Play JSON 密钥路径 |
| [Android Gradle](/Users/dylan/Desktop/candao/tappo_phone/apps/mobile/android/app/build.gradle.kts) | 上传签名、SDK、安装权限移除 |
| [iOS Fastfile](/Users/dylan/Desktop/candao/tappo_phone/apps/mobile/ios/fastlane/Fastfile) | IPA 归档导出、TestFlight、Shorebird、钉钉 |
| [iOS Appfile](/Users/dylan/Desktop/candao/tappo_phone/apps/mobile/ios/fastlane/Appfile) | Bundle ID、Apple ID；团队参数部分仍为注释 |
| [Flutter 包装脚本](/Users/dylan/Desktop/candao/tappo_phone/apps/mobile/ios/fastlane/flutter_build.sh) | 清理 Ruby/Bundler 环境后执行 Flutter/Shorebird |
| [版本文件](/Users/dylan/Desktop/candao/tappo_phone/apps/mobile/pubspec.yaml) | 双端版本、App 依赖、Shorebird 配置资源 |
| [环境配置](/Users/dylan/Desktop/candao/tappo_phone/apps/mobile/lib/config/app_env.dart) | QC/生产 Web 和 API 地址 |
| [更新配置](/Users/dylan/Desktop/candao/tappo_phone/packages/core_update/lib/src/update_config.dart) | office/store、iOS 商店 ID |
| [应用启动](/Users/dylan/Desktop/candao/tappo_phone/apps/mobile/lib/main.dart) | 调试工具实际开启条件 |
| [Shorebird 配置](/Users/dylan/Desktop/candao/tappo_phone/apps/mobile/shorebird.yaml) | App ID、自动更新开关 |
| [更新日志脚本](/Users/dylan/Desktop/candao/tappo_phone/apps/mobile/scripts/generate_changelog.rb) | 从 Git 提取通知摘要、创建本地 BUILD tag |
| [OSS 配置模板](/Users/dylan/Desktop/candao/tappo_phone/apps/mobile/scripts/oss_config.sh.example) | OSS 上传参数模板 |
| [.fvmrc](/Users/dylan/Desktop/candao/tappo_phone/.fvmrc) | 普通 Flutter 构建版本 |

Android、iOS 各有 `Gemfile`、`Gemfile.lock`、`fastlane/.env.example`。应分别安装依赖，不能假定两端 Fastlane/Bundler 版本相同。

## 3. 当前配置快照

| 项目 | 当前值／来源 |
|---|---|
| 版本 | `1.0.4+7`，必须每次读取 pubspec，不要沿用本文快照 |
| 包名／Bundle ID | `com.tappotechnologylimited.mobile` |
| App 名称 | Tappo Pulse；更新模块显示名另为 `TAPPO` |
| FVM Flutter | `3.41.0` |
| Android AGP / Gradle / Kotlin | `8.11.1` / `8.14` / `2.2.20` |
| Java/Kotlin 目标 | 17；构建机实际 JDK 另行检查 |
| Android SDK/NDK | 取 Flutter Gradle 扩展默认值，非脚本固定数字 |
| iOS 最低版本 | Podfile、Xcode project 均为 `15.0` |
| iOS 方向 | iPhone 竖屏；iPad 竖屏及倒置竖屏，`UIRequiresFullScreen=true` |
| iOS workspace / scheme | `Runner.xcworkspace` / `Runner` |
| iOS 导出方式 | `app-store`，自动签名 |
| 默认开发团队 | `PC4A7P943C`；Xcode 工程也设置此团队 |
| Android 锁文件 | Fastlane `2.229.0`，Bundler `2.7.2` |
| iOS 锁文件 | Fastlane `2.240.1`，CocoaPods `1.17.0`，Bundler `4.0.16` |

### 环境与渠道

| 参数 | 默认与实际效果 |
|---|---|
| `--dart-define=flavor=qc` | 默认环境；Web `https://ab-v6-qc-tappo-phone.can-dao.com/`，API 同域无末尾 `/` |
| `--dart-define=flavor=prod` | Web `https://pulse.gotappo.com/`，API `http://pulse.gotappo.com` |
| `--dart-define=update_channel=store` | 默认渠道；整包更新走商店 |
| `--dart-define=update_channel=office` | Android 自分发，允许 APK 下载及安装策略 |
| `--android-project-arg=officeChannel=true` | 与 office 渠道成对，保留 `REQUEST_INSTALL_PACKAGES` |
| `--dart-define=enable_dev_tools=true` | 只在非 release 构建启用相应工具；UME 在 debug 模式默认开启 |
| `--dart-define=ios_app_store_id=...` | 运行时商店跳转 ID，默认空；现有 lane 未提供注入入口 |

`AppEnv.current` 未传 flavor 或传错值都会落入 QC。Android build_args 校验 channel，只允许 office/store；flavor 没有同等校验。生产任务必须显式传 prod，不能依靠 release 模式推断环境。生产 API 当前明确是 HTTP，本文没有改为 HTTPS；应在真机验收中核实网络访问。

iOS lane 没有显式传 update_channel，依赖代码默认 store。环境参数编译进包，上传阶段不能切换环境。

## 4. Android 公共入口（8 个）

工作目录：`/Users/dylan/Desktop/candao/tappo_phone/apps/mobile/android`。
调用形式：`bundle exec fastlane <lane> [参数]`。
下表的“工具=true”表示传入参数，不保证 release 模式实际开启工具。

| lane | 模式 / 环境 / 渠道 | 工具参数 | 产物与外部动作 |
|---|---|---|---|
| `build_debug_apk` | debug / qc / office | true | debug APK，仅本地 |
| `build_qc` | release / qc / office | true | QC APK；DUFS + OSS QC；摘要/tag；钉钉 |
| `build_release_apk` | release / prod / office | false | 正式 APK + latest.apk；两个文件上传 OSS release；摘要/tag；钉钉 |
| `build_release_devtools` | release / prod / office | true | 正式 APK，仅本地；实际工具被 release 条件关闭 |
| `build_release_aab` | release / prod / store | false | AAB，仅本地，不上传 Google Play |
| `build_shorebird_apk` | Shorebird release / prod / office | false | 上传 Shorebird 基线；APK + latest.apk 上传 OSS；摘要/tag；钉钉 |
| `build_shorebird_aab` | Shorebird release / prod / store | false | 上传 Shorebird 基线；AAB 本地，不上传 Google Play |
| `patch_android` | Shorebird patch / 可选环境及渠道 | qc 时 true | 上传补丁至 Shorebird；无 APK 分发及钉钉调用 |

参数：

- 两个 `build_shorebird_*` 接受 `flutter_version`，默认 `3.41.0`，不自动跟随 .fvmrc。
- `patch_android release_version:<名称+构建号> [flavor:prod|qc] [channel:office|store]`。release_version 必填；默认 prod/office。Play 基线补丁必须显式 channel:store。
- 普通 lane 没有读取 options，不能假设附加 `flavor:prod`、`upload:false`、`build_number:8` 就会生效。例如 `build_debug_apk flavor:prod` 仍按脚本固定 QC 构建。
- 当前没有生产 debug、QC 本地 release、生产 APK 仅 DUFS、已有 APK 上传等独立公共 lane。

### Android 执行流程

1. 查找 App 目录及 workspace 根的 `.fvmrc`，兼容 `.fvm/fvm_config.json`。
2. 依次查找多个用户 FVM SDK 路径；失败回退字符串 `fvm flutter`。
3. 设置 `GRADLE_USER_HOME=apps/mobile/android/.gradle-home`；目录内没有 gradle.properties 时复制用户全局配置。
4. 尝试停止 Gradle daemon（失败忽略），执行 Flutter clean、pub get。
5. 等待 workspace/App 的 package_config 最多约 5 秒，仍未出现只告警。
6. 根据 lane 组装 define 和 Gradle 渠道参数，构建、复制产物。
7. 按 lane 固定顺序分发、生成摘要/tag、通知。

Shorebird office 构建将 `--android-project-arg` 放到 `--` 后转交 Flutter。其余 Shorebird 参数兼容性须按部署的 CLI 版本检查，本文仅描述现有命令。

## 5. iOS 公共入口（7 个）

工作目录：`/Users/dylan/Desktop/candao/tappo_phone/apps/mobile/ios`。
调用形式：`bundle exec fastlane <lane> [参数]`。

| lane | 环境 / 工具参数 | 执行行为 |
|---|---|---|
| `build_qc` | qc / true | release 编译，签名导出本地 IPA |
| `build_release` | prod / false | release 编译，签名导出本地 IPA |
| `release` | prod / false | IPA + TestFlight 上传 + 摘要/tag + 钉钉 |
| `release_debug` | prod / true | 同上，但仍是 release 编译，不是 debug IPA |
| `test` | qc / true | QC IPA + TestFlight + 摘要/tag + 钉钉；不是运行测试套件 |
| `release_shorebird` | flavor 默认 prod / false | Shorebird 基线、现成 archive 导出 IPA、TestFlight、摘要/tag、钉钉 |
| `patch_ios` | flavor 默认 prod；qc 时工具 true | 上传 Shorebird 补丁；无 TestFlight/钉钉调用 |

`release_shorebird` 接受 flavor、flutter_version（默认 3.41.0）。`patch_ios` 要求 release_version，可传 flavor。其他公共 lane 固定环境，没有通用 options。

### iOS 执行流程

普通 IPA：`flutter clean` → `flutter pub get` → `flutter build ios --release <defines>` → Fastlane `build_app` 再归档并导出 IPA。

`build_app` 使用 Runner workspace/scheme、`app-store` 导出、自动签名、`-allowProvisioningUpdates`。普通路径没有 `skip_build_archive`，不能把前面的 Flutter build 当作最终唯一一次编译；必须验证最终 IPA 的环境与版本。

Shorebird IPA：`shorebird release ios --flutter-version ... --no-codesign <defines>` → `build_app(skip_build_archive: true)` 导出 `build/ios/archive/Runner.xcarchive` → 上传。这里不能额外用普通 Flutter 重建 archive，否则会替换 Shorebird 引擎。

`flutter_build.sh` 清除 BUNDLE_*、GEM_HOME/GEM_PATH、RUBYOPT 等环境变量，切到 App 目录，然后执行第一个参数作为命令。需要特别注意：

- 若 Flutter 路径查找失败而回退为字符串 `fvm flutter`，包装脚本把它当作一个可执行文件名，可能报找不到文件。构建机应确保直接 SDK 路径能解析。
- 参数经 `$@` 保存为字符串再非引号展开，带空格路径/参数可能被拆分。
- 清除 Bundler 环境后，CocoaPods 必须仍能在子进程 PATH 下运行；仅 `bundle check` 成功不足以证明 `pod` 可用。

## 6. 签名与凭据契约

本文不记录密码、Token、私钥内容。打包系统应接收 credential reference，由执行节点短时注入。

### Android

| 变量 | 优先级／含义 |
|---|---|
| `TAPPO_PHONE_KEYSTORE_PATH` | 优先；否则用户目录 `.config/tappo_phone/android/tappo-pulse-upload.jks` |
| `TAPPO_PHONE_STORE_PASSWORD` | 优先；否则 macOS Keychain service `tappo_phone.android.upload.store_password` |
| `TAPPO_PHONE_KEY_PASSWORD` | 优先；否则复用 store password |
| `TAPPO_PHONE_KEY_ALIAS` | 优先；默认 `tappo-pulse-upload` |
| `GOOGLE_PLAY_JSON_KEY_FILE` | Appfile 读取；当前无 Play 上传 lane，不会仅凭此变量自动上传 |

release task 请求时缺少密钥文件/密码/alias 会立即报错。release APK、AAB 使用同一签名配置；debug 使用 Android debug 签名。系统应记录证书 SHA256，不仅记录 alias。

### iOS

- 构建需要 Xcode、可用签名证书及私钥、描述文件或自动签名授权；App Store Connect API Key 不能代替代码签名身份。
- `TEAM_ID` 控制导出 teamID，默认 PC4A7P943C；Xcode 工程的 DEVELOPMENT_TEAM 也需要一致，不能认为只改环境变量就切换整个团队。
- `APPLE_ID` 由 Appfile 读取，用作 API Key 不可用时的交互认证回退。
- API Key 要求三项同时有效：`APP_STORE_CONNECT_API_KEY_KEY_ID`、`APP_STORE_CONNECT_API_KEY_ISSUER_ID`、`APP_STORE_CONNECT_API_KEY_KEY`。
- 最后一项是 .p8 文件路径，相对路径以 iOS fastlane 目录解析；文件内容传给 `app_store_connect_api_key`，duration=1200，in_house=false。
- 缺任意一项会回退 Apple ID，而非预检失败；无人值守系统建议在执行前阻断，避免等待交互。
- Appfile 的 team_id/itc_team_id 为注释；`.env.example` 出现 ITC_TEAM_ID 不代表当前已接入。
- 当前方案按包含 Issuer ID 的团队 Key 编写，未实现个人 Key 无 issuer 的分支。

### Shorebird

App ID 为 `649c3680-7a1a-4079-bffd-1dfec90b443f`，QC/生产与各渠道共用一个配置。`auto_update:false`，应用更新服务主动检查和下载。CI 预期提供 SHOREBIRD_TOKEN；脚本未主动验证登录、配额及基线是否存在。

补丁必须与对应基础包的版本、平台、环境、渠道及 define 一致。当前 iOS 存在具体不一致：`release_shorebird flavor:qc` 未打开工具参数，而 `patch_ios flavor:qc` 会添加工具参数。需要在接入前统一，而不是直接开放任意组合。Android 没有 QC Shorebird 基线公共 lane，但补丁 lane 允许 qc。

## 7. 产物和版本

所有命名中的日期使用构建节点本地 `Time.now`，没有固定时区。建议执行节点统一 Asia/Shanghai 并记录 UTC 时间戳。

输出目录：`apps/mobile/build/outputs`。日期记作 D，pubspec 的版本名称记作 V。

| 入口 | 归档文件名 |
|---|---|
| Android debug | `tappo_phone_D_vV_debug.apk` |
| Android QC | `tappo_phone_D_vV_qc.apk` |
| Android release | `tappo_phone_D_vV_release.apk`，另复制 `latest.apk` |
| Android release_devtools | `tappo_phone_D_vV_release_devtools.apk` |
| Android AAB | `tappo_phone_D_vV_release.aab` |
| Android Shorebird | `shorebird_tappo_phone_D_vV_release.apk` 或 `.aab`；APK 另有 latest.apk |
| iOS 普通 | `tappo_phone_D_vV_prod.ipa` / `..._prod_devtools.ipa` / `..._qc_devtools.ipa` |
| iOS Shorebird | `shorebird_tappo_phone_D_vV_<flavor>.ipa` |

Android 原始产物：`build/app/outputs/flutter-apk/app-debug.apk`、`app-release.apk`、`build/app/outputs/bundle/release/app-release.aab`（相对 App 目录）。iOS Fastlane 最终产物以上述 output_directory 为准，不应只扫描 Flutter 默认 `build/ios/ipa`。

版本名称和构建号来自 App pubspec。lane 不自动递增，不查询商店占用情况，也没有统一 --build-number 参数入口。文件名不带 build number 或 commit，同一天重复构建会覆盖；latest.apk 在普通/Shorebird release 间也共用。

建议存储键包含：项目、平台、环境、渠道、引擎、versionName、buildNumber、commit、jobId。产物必须在下一次 clean 前移至任务独立持久目录。

## 8. 分发、通知和摘要的真实结果语义

### DUFS

默认服务 `http://192.168.225.46:5000/dufs`，ENV DUFS_SERVER 可覆盖；目录固定 TAPPO_PHONE，无 DUFS_FOLDER 环境变量入口。账号通过 DUFS_USERNAME/DUFS_PASSWORD，代码含默认凭据，系统必须用受控凭据覆盖。

先 GET 目录，200/301 视为存在，否则尝试 MKCOL。目录创建返回值未阻断后续上传。上传采用 Basic Auth + HTTP PUT，读取整个文件到内存；连接超时 5 秒、上传读取超时 300 秒，返回 <300 视为成功，否则 nil。缺少上传后 hash/大小校验。

### OSS

从 `apps/mobile/scripts/oss_config.sh` 逐行解析，不执行 shell、不直接读同名环境变量。只接受形如 `KEY="value"` 的行；不支持 export、单引号或变量展开。

必需字段：OSS_ENDPOINT、OSS_ACCESS_KEY_ID、OSS_ACCESS_KEY_SECRET、OSS_BUCKET、OSS_PATH_RELEASE、OSS_PATH_QC。即使只发 release，QC 路径也被列为必需。缺文件/字段返回 nil，不中断。

签名使用 OSS V1 HMAC-SHA1；URL 拼为 `https://<endpoint>/<folder>/<filename>`，签名资源为 `/<bucket>/<folder>/<filename>`。脚本不会把 bucket 自动加到 endpoint，配置必须确保 endpoint 实际路由到对应 bucket；模板的裸地域 endpoint 不能直接视为已验证可用。

curl 使用连接超时 30 秒、总超时 600 秒、--noproxy endpoint；仅退出成功且 HTTP 200/201 才返回 URL。版本文件与 latest.apk 分别上传，任一失败不回滚另一项。

### TestFlight

设置 `skip_waiting_for_build_processing:true`、`skip_submission:true`。完成上传不等于处理成功、可测试或审核通过。

出现包含 WILL RETRY、network connection was lost、-1005 的异常会被吞掉，调用者仍打印“已上传”、创建摘要并通知。此路径必须在系统中标为 unknown，查询 Apple 构建状态后再转成功；不能据日志成功字样判定。

### 钉钉

读取 DINGTALK_WEBHOOK，空值跳过。发送 markdown JSON，Android 附下载链接，iOS 描述分发为 TestFlight。未解析返回 JSON 的 errcode，curl 也没有 --fail 和显式超时，因此业务拒收或 HTTP 错误可能仍显示已发送，网络也可能长期等待。

Webhook 放在 shell 命令中，存在日志/进程参数暴露风险，未来执行器必须脱敏。QC 同时上传两个服务时，将 DUFS 的版本文件 URL 当 latest_url 传入，文案会误标为 latest.apk。

### Changelog 与 Git 副作用

起始点依次为最新 BUILD-* tag、前一个版本变更提交、main。读取非 merge commit subject，解析 Conventional Commits，主要展示 feat/fix/perf/refactor，每类默认最多 5 项。

非空摘要且 create_tag=true 时创建本地轻量 `BUILD-YYYYMMDD-HHMMSS` tag，不 push。创建 tag 返回值没有严格验证；找不到 main 或起始 ref 时 stderr 被吞掉，可能只是空摘要。一个仓库各平台/环境共用 BUILD 前缀，会相互推进摘要起点。

## 9. 给打包系统的最小接口建议（尚未实现）

先做一个任务执行器和产物记录，不引入自定义构建框架。复用 lane 时只能开放其真实支持的组合；其他组合显示“不支持”，不能给用户看似可用但被忽略的参数。

### 请求字段

| 字段 | 建议约束 |
|---|---|
| source_ref | 提交 SHA；同时记录工作区是否脏，发布默认使用独立干净 checkout |
| platform / artifact | android: apk/aab；ios: ipa；patch 作为独立任务类型 |
| environment | qc/prod 枚举；禁止默认回退 QC |
| build_mode | debug/release；App Store IPA 只能 release |
| channel | Android office/store；iOS 当前 store |
| engine | flutter/shorebird |
| version_name / build_number | 全局预留并校验；检查商店版本冲突；只在任务 checkout 写入 |
| release_version | patch 必填，目标基线明确版本，不默认 latest |
| distribute_to | local/dufs/oss/testflight；google_play 当前未实现 |
| notify | 可选；带确认过的接收目标引用 |
| credentials | 引用，不接受明文密钥进入任务日志 |

当前 Fastlane 不直接消费上述统一字段。第一版可把支持的固定组合映射为 lane；需要分离上传或自由组合时，新增少量明确的 build-only/upload-only 入口，不用拼接任意用户命令。

### 结果字段

记录 jobId、commit、dirty、精确命令参数（脱敏）、工具版本、环境/渠道、版本、开始结束时间；每件产物记录绝对路径、文件大小、SHA256、签名身份、包内版本、下载 URL。

分别保存 `build`、`validate`、`distribution`、`notification` 的状态：pending/running/succeeded/failed/skipped/unknown。TestFlight 另记录 Apple 接收和处理状态；Shorebird 另记录 release/patch 标识。外部动作执行前保存用户确认的目的地和范围。

### 执行流程

1. 解析配置及参数，校验支持组合、签名、工具路径、网络与版本占用。
2. 获取单个 checkout 的互斥锁，或为任务建立隔离 checkout。双端不可在同一 App build 目录同时执行 clean/build。
3. 确认上传/通知目的地。仅本地任务不得调用包含上传副作用的 lane。
4. 构建，设置进程超时和取消策略；日志脱敏。
5. 检查真实包内版本、域名、签名、渠道权限及 iOS plist，不以文件名替代验证。
6. 将产物复制至持久存储，计算 SHA256，再按需上传。
7. 上传完成读回大小/hash或查询商店回执；unknown 先查询再重试，避免重复发布。
8. 独立发送通知并解析业务结果；通知失败不重建、不重传产物。

建议最先补齐：生产 APK build-only、已有产物 upload-only、DUFS 目标选择、严格上传/通知结果、带构建号文件名。Google Play 自动上传、定时构建等可等明确需求再加。

## 10. 直接使用现有入口

以下是现有命令示例，不代表本次已执行。准备 Ruby/Bundler 后，在对应平台目录运行。上传/热更/通知必须已明确授权。

```bash
# Android：生产 Play AAB，仅本地产物
cd /Users/dylan/Desktop/candao/tappo_phone/apps/mobile/android
bundle exec fastlane build_release_aab

# Android：生产 APK，并自动 OSS 上传、钉钉通知（凭据存在时）
bundle exec fastlane build_release_apk

# Android：Shorebird Play 基线（会上传 Shorebird）
bundle exec fastlane build_shorebird_aab flutter_version:3.41.0

# Android：补丁；版本号必须替换成真实已发布的 Shorebird 基线
bundle exec fastlane patch_android release_version:1.0.4+7 flavor:prod channel:store

# iOS：生产 IPA，仅本地
cd /Users/dylan/Desktop/candao/tappo_phone/apps/mobile/ios
bundle exec fastlane build_release

# iOS：生产 IPA + TestFlight + 钉钉
bundle exec fastlane release

# iOS：Shorebird 基线 + TestFlight + 钉钉
bundle exec fastlane release_shorebird flavor:prod flutter_version:3.41.0
```

本地自定义构建可使用 Flutter 原生命令，例如生产 debug APK；它不属于现有固定 lane：

```bash
cd /Users/dylan/Desktop/candao/tappo_phone/apps/mobile
GRADLE_USER_HOME="$PWD/android/.gradle-home" fvm flutter build apk --debug \
  --dart-define=flavor=prod \
  --dart-define=update_channel=office \
  --dart-define=enable_dev_tools=true \
  --android-project-arg=officeChannel=true
```

## 11. 本次验证范围

逐项静态核对两端全部 15 个公共 lane、环境/版本/签名来源、外部调用、资源命名和错误处理。文档链接与 lane 覆盖由本地检查验证。没有运行外部发布、检查实际账号权限、验证在线 Shorebird 基线或重新构建任何安装包。

本文件是打包系统开发输入，不是已上线系统的 API 契约；接入时应先修复第 8 节的结果判定和第 9 节列出的最小缺口，再对受控测试目标做一次完整验收。
