# 打包脚本解析与独立打包系统接入说明

本文解析 flutter-hpos 当前仓库的真实构建行为，供后续独立打包系统设计、实现和验收使用。**“现状”是已有实现；“建议”是尚未实现的系统契约。**

- 分析日期：2026-09-23。
- 源码基线：`00023336eb28f50d579668f2f2609ff251e8a6c7`，以本次工作区文件为准。
- 当前版本：`pubspec.yaml` 的 `1.9.1+14`；包内版本名为 `1.9.1`，构建号为 `14`。
- 本次仅新增本文。未实际编译、签名、上传、修改远程版本记录或发送通知。
- 原有未跟踪文件 `devtools_options.yaml`、`docs/web_to_flutter_migration_usage_guide.md` 保留。

## 1. 结论与入口选择

项目有两套独立入口，不能把它们当成同一流程的两个调用方式。

| 入口 | 支持范围 | 特点 | 系统接入限制 |
| --- | --- | --- | --- |
| 根目录 Shell | Android APK/AAB；iOS APP/IPA | 环境检查、格式检查、分析、代码生成、构建、上传、通知 | 没有“只构建”开关；参数校验不完整；iOS 导出未形成可复现配置 |
| Android Fastlane | Android APK | 六个固定 lane；普通 lane 全为 release 编译；含 Rust/Cargokit 准备 | 无格式/分析/代码生成步骤；没有 iOS、AAB、预生产 lane；没有只构建开关 |

建议系统第一期复用现有构建命令和环境映射，先支持 Android APK。将构建、归档上传、生产版本发布、通知分为独立阶段。不要直接把现有脚本作为无副作用的“编译命令”。iOS 与正式签名需要单独补齐并实测后再开放。

源码入口：

- [Shell 脚本](/Users/dylan/Desktop/candao/flutter-hpos/build_handhelp_pos.sh)
- [Fastlane](/Users/dylan/Desktop/candao/flutter-hpos/android/fastlane/Fastfile)
- [Fastlane Appfile](/Users/dylan/Desktop/candao/flutter-hpos/android/fastlane/Appfile)

## 2. Shell 参数契约

工作目录必须为项目根目录。脚本不根据自身路径自动切换目录。

| 参数 | 默认值 | 接受值／实际行为 |
| --- | --- | --- |
| `--platform` | `android` | `android`、`ios`；iOS 要求 `OSTYPE` 为 darwin |
| `--type` / `-t` | `debug` | `debug`、`test-prod`、`pre-prod`、`release`；实际到 `build_app` 才校验 |
| `--proxy` / `-p` | `none` | `1`、`2`、`none`；改变文件名和 Dart define，见第 5 节 |
| `--format` / `-f` | `apk` | Android 只接受 apk/aab；iOS 将其他值自动改为 ipa |
| `--flutter-version` / `-v` | `3.35.0` | 只赋值、打印，未传入 FVM，也不验证实际 SDK |
| `--no-fvm` | 不启用 | 启用后使用 PATH 中的 flutter/dart |
| `--validate-only` | 不启用 | 仅部分配置检查；Android APK 仍读取 OSS 凭据并检查 curl/openssl |
| `--help` / `-h` | — | 打印帮助后退出 |

没有版本名、构建号、输出目录、签名、上传开关、通知开关、任意 Dart define 参数。输出目录固定为 `build/outputs`。

**参数缺值风险：**解析器直接读取 `$2` 并 `shift 2`，没有缺值检查。系统必须在调用前完整校验，避免解析失败或卡住。

**validate-only 不是 dry-run，也不是环境健康检查：**不检查 Flutter、依赖、签名或实际产物，不输出完整最终命令，甚至不会校验 build type。本次安全验证使用 Android AAB，传入 `invalid-type` 和 SDK `0.0.0`，仍返回 0 并声称验证通过。

## 3. 编译模式、业务环境与 UME

实际调用链为 `lib/main.dart: main → _setupEnvironment → EnvConfig.setEnvironment`。不能依据包名里的 debug/release 判断业务环境。

### 3.1 Shell 构建矩阵

| type | Flutter 模式 | 注入 define（不含可选 proxy） | 应用环境 | UME | 文件名环境段 |
| --- | --- | --- | --- | --- | --- |
| debug | debug | 无 | development / QC 域名 | 开 | debug |
| test-prod | release | `test_production=true` | testProduction / QC 域名 | 关 | test_prod |
| pre-prod | release | `pre_production=true`、`show_ume=true` | preProduction | 开 | pre_prod |
| release | release | 无 | production | 关 | release |

### 3.2 Fastlane 构建矩阵

从项目的 `android` 目录调用 `bundle exec fastlane android <lane>`。普通 lane 的构建命令均为：

```text
fvm flutter build apk --release --dart-define=show_ume=<true|false> [额外 define]
```

| lane | show_ume | 额外 define | 应用环境 | OSS 版本别名 |
| --- | --- | --- | --- | --- |
| qc_debug | true | `test_production=true` | QC | 不更新 |
| qc | false | `test_production=true` | QC | 不更新 |
| test_prod | false | `test_production=true` | QC | 不更新 |
| release | false | 无 | 生产 | 更新 `{version}.apk` |
| release_debug | true | 无 | 生产 | 不更新 |
| appium_test | 未设置 | 使用专用测试入口、Gradle debug 构建 | development / QC | 不上传 OSS |

`qc` 和 `test_prod` 编译参数相同，区别是产物名称与通知标签。`release_debug` 是生产环境的 release 编译包，额外展示 UME；不是 QC 包，也不是 Flutter debug 包。

### 3.3 环境优先级和端点

环境优先级：`test_production=true` 优先于 `pre_production=true`，然后按 release/profile/debug 模式选择 production/staging/development。系统应禁止同时设置两种环境 define。

UME 开关为 `show_ume || kDebugMode || pre_production`。因此仅传 `show_ume=false` 不能关闭 debug 或预生产的 UME。

| 环境 | API 默认地址 | WebView 默认地址 | 测试功能默认启用 |
| --- | --- | --- | --- |
| development / staging / testProduction | `http://candao-api-gateway.toa-v6-qc.can-dao.com` | `https://toa-v6-qc-handheld.can-dao.com/#/` | 是 |
| preProduction | `https://toa-handheld-pre.can-dao.com.hk` | `https://toa-handheld-pre.can-dao.com.hk/#/` | 否 |
| production | `https://toa-api-gateway.can-dao.com.hk` | `https://toa-handheld.can-dao.com.hk/#/` | 否 |

这些是配置默认值。持久化的自定义 WebView URL 可以覆盖 WebView 默认地址；实际设备验收应检查存量配置。`show_ume` 只控制浮层展示，不等价于开启所有测试功能；FeatureFlagService 还维护运行时功能开关。

证据：[main.dart](/Users/dylan/Desktop/candao/flutter-hpos/lib/main.dart:14)、[EnvConfig](/Users/dylan/Desktop/candao/flutter-hpos/lib/core/config/env_config.dart:16)、[FeatureFlagService](/Users/dylan/Desktop/candao/flutter-hpos/lib/core/network/feature_flag_service.dart)。

## 4. 构建流水线逐步解析

### 4.1 Shell

1. 解析参数，校验代理枚举、平台与格式。
2. Android APK 预检 OSS 凭据及 curl/openssl；所有 type 都检查，不仅 release。
3. 如果 validate-only，直接退出。
4. 检查 FVM 和 `.fvmrc`；执行 `fvm install`、`fvm use --force`。no-fvm 模式只检查 PATH 中 Flutter。
5. 打印 Flutter/Dart 版本；脚本只比较 Dart 主次版本是否达到 3.9.0，低于时交互询问。此阈值落后于当前 pubspec 的 `^3.10.0`。
6. 执行 Flutter doctor、`flutter pub get --enforce-lockfile`。
7. `dart format --output=none --set-exit-if-changed` 检查 lib/test，及存在的 integration_test/test_driver/tool/tools。格式不合规直接退出，不改源码。
8. Flutter analyze 失败：有终端时询问是否继续；非交互模式直接继续。
9. 执行 `tools/generate_resources.dart`，再执行 `dart run build_runner build --delete-conflicting-outputs`。
10. 在 `build_app` 中校验 type，生成并执行 Flutter 命令，复制产物。
11. Android APK 上传 OSS；release 额外更新版本别名。
12. 创建 DUFS 目录并上传；iOS APP 先压为 APP.ZIP。
13. DUFS 上传返回成功后发送钉钉通知。

源码位置：[环境准备](/Users/dylan/Desktop/candao/flutter-hpos/build_handhelp_pos.sh:156)、[质量检查](/Users/dylan/Desktop/candao/flutter-hpos/build_handhelp_pos.sh:238)、[构建](/Users/dylan/Desktop/candao/flutter-hpos/build_handhelp_pos.sh:545)、[主流程](/Users/dylan/Desktop/candao/flutter-hpos/build_handhelp_pos.sh:689)。

工作区副作用：FVM 可能准备 SDK/项目链接；代码生成会重写 `lib/core/constants/r.dart` 和数据库生成文件。资源生成文件还写入当前时间，并通过 PATH 中的 `dart` 格式化，与外层 FVM 选择不一定一致。成功路径不执行 clean；脚本配置了 ERR trap 尝试 clean，但没有 `set -E`，函数内错误不能保证执行该清理。

### 4.2 Fastlane 普通 lane

`lane → build_apk → upload_to_dufs → upload_release_apk_to_oss → send_dingtalk`。

`build_apk` 内部：

1. 验证 OSS 凭据。
2. 切到计算得到的项目根目录。
3. `fvm flutter pub get --enforce-lockfile`。
4. `rustup target add --toolchain stable`，准备 aarch64-linux-android、armv7-linux-androideabi、x86_64-linux-android。
5. 尝试准备 Cargokit 缓存。
6. 执行 release APK 构建并复制产物。
7. 返回 file_path、file_name、lane_label、version 给 lane 上传。

与 Shell 不同：不执行 fvm install/use、doctor、格式检查、analyze、资源生成、build_runner 或测试。新系统若只接 Fastlane，不能认为这些检查已执行。

`project_root` 用 `File.expand_path('../..')` 缓存结果，依赖 Fastlane 的运行目录语义。应固定从 android 目录启动，不随意从仓库外通过自定义加载器执行。

### 4.3 Cargokit 特殊处理

仅 Fastlane 有缓存预下载辅助逻辑。读取代理变量优先级为 `https_proxy → HTTPS_PROXY → http_proxy → HTTP_PROXY`。

- 没有代理时直接跳过预下载。
- 仅处理 `irondash_engine_context` 和 `super_native_extensions`。
- 依赖 `build/<package>/build/precompiled` 已存在，且内部已有 32 位十六进制 crate hash 目录；干净工作区可能直接跳过。
- 对三个 Android target 下载 `.so` 和 `.so.sig`；非空已存在文件直接复用。
- 下载使用 GitHub releases、curl，连接超时 30 秒、总超时 120 秒；非 200 时删掉失败文件并记录错误。
- 缓存预下载失败不直接终止 helper，后续构建仍可能依靠原生下载或 Rust 编译失败。

系统不能把此 helper 当成完整离线缓存初始化。Rust stable 未锁精确版本；需要记录实际工具版本及原生依赖来源。

### 4.4 Appium lane

与普通 lane 分开：执行非锁定模式 `fvm flutter pub get`，尝试缓存预下载，但不执行上述 rustup target 准备。检查入口后执行：

```text
cd android && ./gradlew app:assembleDebug -Ptarget=<项目根目录>/integration_test/appium_test.dart
```

读取 `build/app/outputs/apk/debug/app-debug.apk`，复制到归档目录，只上传 DUFS 和发送钉钉。入口直接初始化 development 环境并挂载 MyApp，不走普通 main 的 UME 包装。

证据：[Appium lane](/Users/dylan/Desktop/candao/flutter-hpos/android/fastlane/Fastfile:409)、[测试入口](/Users/dylan/Desktop/candao/flutter-hpos/integration_test/appium_test.dart)。

## 5. 代理的两种含义

Shell `--proxy 1` 注入 `--dart-define=proxy_type=1`，文件名用 `192_168_220_57_9091`；值 2 对应 `192_168_225_34_8888`；none 不注入 define，文件名用 `no_proxy`。

**当前 lib 中未找到 `proxy_type` 读取点。**实际应用代理经 ProxyManager 和 SharedPreferences 的 `network_proxy` 设置，并受 FeatureFlagService 控制。因此不能承诺 `--proxy 1/2` 已让安装包自动使用对应代理；none 也不能保证设备没有保存过运行时代理。

Fastlane 的代理环境变量用于构建机下载，与 App 网络代理不同。OSS 的 curl 上传分支显式 `--noproxy '*'`，绕过代理；ossutil 分支没有相同显式设置。系统参数应区分“构建网络代理”与“应用运行时代理”，后者当前不应以脚本参数作为已支持能力。

证据：[ProxyManager](/Users/dylan/Desktop/candao/flutter-hpos/lib/core/network/proxy_manager.dart)。

## 6. 工具链与签名条件

| 项目 | 当前配置 | 接入要求 |
| --- | --- | --- |
| Flutter | `.fvmrc`：3.38.9 | 以项目配置和实际 SDK 输出为准，不能用脚本打印的 3.35.0 |
| Dart | pubspec：`^3.10.0` | 校验真实 Dart 版本；Shell 3.9.0 检查不足 |
| Flutter 依赖 | 已提交 pubspec.lock | 普通流程 enforce-lockfile；Appium 例外 |
| Java | Android Java/Kotlin 目标 17 | 准备兼容 JDK，记录实际版本 |
| Gradle | wrapper 8.12 | 用仓库 wrapper |
| Android Groovy 配置 | AGP 8.9.1、Kotlin 2.1.0、compileSdk 36 | minSdk/targetSdk/NDK 随 Flutter 配置解析 |
| Android Kotlin DSL 副本 | AGP 8.11.1、Kotlin 2.2.20、compileSdk 随 Flutter | 与 Groovy 并存；标准 Gradle 同名解析优先 Groovy，不能把两套值混用；运行日志复核有效配置 |
| Fastlane | Gemfile.lock 锁定 2.232.0；Bundler 2.7.2 | 在 android 目录用 bundle 管理；当前锁文件含 arm64-darwin-23/ruby 平台 |
| 原生构建 | Fastlane 使用 rustup stable | 记录并固定系统需要的 Rust/target；干净节点实测 |
| iOS | macOS、Xcode、CocoaPods；已提交 Podfile.lock | 脚本未安装或锁定 Xcode/CocoaPods，未指定 export-options |

Android 包名为 `com.example.handhelp_pos`，版本来自 Flutter/pubspec。**两份 app Gradle 文件的 release 都使用 debug signingConfig。**因此“release 模式”不代表“正式发布签名”；不同构建机默认 debug keystore 可能导致更新安装签名不一致。迁移系统前应确认现网签名指纹与密钥归属，不能自行替换签名。

iOS Bundle ID 为 `com.example.handhelpPos`；Xcode 工程可见 deployment target 13.0、iPhone Developer 配置，未发现 DEVELOPMENT_TEAM。脚本没有证书导入、描述文件选择、签名密码管理或 ExportOptions.plist 参数。不能据此保证 IPA 可导出或安装；插件也可能提高最低系统要求，应以实际依赖解析/构建结果为准。

证据：[FVM](/Users/dylan/Desktop/candao/flutter-hpos/.fvmrc)、[pubspec](/Users/dylan/Desktop/candao/flutter-hpos/pubspec.yaml)、[Android app](/Users/dylan/Desktop/candao/flutter-hpos/android/app/build.gradle)、[Android settings](/Users/dylan/Desktop/candao/flutter-hpos/android/settings.gradle)、[Xcode 工程](/Users/dylan/Desktop/candao/flutter-hpos/ios/Runner.xcodeproj/project.pbxproj)、[Podfile](/Users/dylan/Desktop/candao/flutter-hpos/ios/Podfile)。

## 7. 产物与版本规则

### 7.1 Shell

| 平台/模式 | 构建命令主体 | 预期原始产物 |
| --- | --- | --- |
| Android APK | `flutter build apk --<mode>` | `build/app/outputs/flutter-apk/app-<mode>.apk` |
| Android AAB | `flutter build appbundle --<mode>` | `build/app/outputs/bundle/<mode>/app-<mode>.aab` |
| iOS debug | `flutter build ios --debug` | `build/ios/iphoneos/Runner.app` |
| iOS 其他 type | `flutter build ipa --release` | 脚本硬编码 `build/ios/ipa/handhelp_pos.ipa` |

iOS 即使参数 format=ipa，debug 实际也生成 APP，再压成 APP.ZIP 上传，不是 IPA。release IPA 文件名必须实测，脚本的固定假设不能替代实际导出结果。

归档名：

```text
build/outputs/handhelp_pos_<YYYYMMDD>_v<versionName>_<envName>_<proxyName>.<apk|aab|app|ipa>
```

APP 额外生成同名 `.app.zip`。日期取构建机本地时区；同日、同版本、同环境与代理重复构建会命中同名目标。APP 目录重复 `cp -r` 还可能产生嵌套目录。

### 7.2 Fastlane

普通 lane 原始产物固定 `build/app/outputs/flutter-apk/app-release.apk`。归档名：

```text
build/outputs/handhelp_pos_<YYYYMMDD>_v<versionName>_<lane>.apk
```

两套脚本都移除 pubspec 的 `+buildNumber` 再命名，未包含 Git SHA、任务 ID 或时间秒数；只提高构建号也可能覆盖归档。脚本未输出结构化 manifest、SHA-256、签名指纹或包内版本校验。

## 8. 上传、生产版本别名与通知

### 8.1 DUFS

- 地址：`http://192.168.225.46:5000/dufs/HANDHELP_POS/<fileName>`，构建机需要内网可达。
- 使用 Basic Auth；用户名和密码目前硬编码在两套脚本。本文不复制凭据值。
- Shell 先 GET，HTTP 200/301 视为目录存在，否则 MKCOL；Fastlane 直接 MKCOL 且忽略失败。
- 上传使用 curl `-T`。两者均未使用 `--fail` 或明确验证上传 HTTP 状态；HTTP 401/403/500 可能被判成成功。
- 通知下载链接指向 DUFS，不是 OSS；收件人仍受内网和访问权限限制。

### 8.2 OSS

- Bucket：`tappo`；region：`cn-hongkong`。
- 上传 endpoint：`https://oss-cn-hongkong.aliyuncs.com`；原始 host：`tappo.oss-cn-hongkong.aliyuncs.com`。
- 对象前缀：`client/HandPOS/apk`。
- 凭据优先取 `OSS_ACCESS_KEY_ID` 与 `OSS_ACCESS_KEY_SECRET`，必须成对设置；均未设置时，从 `lib/core/service/log_upload/log_upload_config.dart` 解析 App 凭据。
- 两套入口所有普通 Android APK 都上传完整文件名归档。仅 Shell type=release、Fastlane lane=release 额外覆盖 `{versionName}.apk`。
- 有 ossutil 时优先分片：parallel=8、part-size=8Mi、force 覆盖；失败直接返回错误，不自动切回 curl。
- 无 ossutil 时使用 OSS V1 HMAC-SHA1 签名，Content-MD5 留空；curl PUT 要求 HTTP 200，最多 3 次，每次最长 1800 秒，间隔 2 秒。
- 版本别名有 ossutil 时服务端复制；否则再次上传文件。两步非原子操作，可能归档成功、版本别名失败。

应用更新的下载链是：版本接口有效 URL 优先；缺失时根据后端版本号回退至：

```text
https://static2.gotappo.com/client/HandPOS/apk/<version>.apk
```

上传原始 host 与 APK 下载 CNAME 不能混用。现有脚本**没有写入后端版本发布记录**；上传 `{version}.apk` 不等于客户端已收到升级版本。

证据：[Shell OSS](/Users/dylan/Desktop/candao/flutter-hpos/build_handhelp_pos.sh:384)、[Fastlane OSS](/Users/dylan/Desktop/candao/flutter-hpos/android/fastlane/Fastfile:172)、[更新 URL 选择](/Users/dylan/Desktop/candao/flutter-hpos/lib/core/service/system_update/system_update_service.dart:232)、[下载兜底配置](/Users/dylan/Desktop/candao/flutter-hpos/lib/core/service/system_update/system_update_oss_config.dart)。

### 8.3 钉钉

机器人 Webhook 硬编码在两套入口，本文不复制 token。通知包含文件名、构建类型、版本、时间和 DUFS 链接；Shell 另含代理标签。Shell 即使构建 iOS，标题仍写 Android。

两者均检查钉钉业务 errcode；发送失败只记录，不作为构建失败。Fastlane 用 JSON 编码和临时文件，Shell 手工拼接 JSON。系统应把“编译成功”“上传成功”“通知成功”分别显示。

### 8.4 顺序差异

- Shell：本地产物、OSS 归档、可选生产别名、DUFS、通知。
- Fastlane 普通 lane：本地产物、DUFS、OSS 归档、可选生产别名、通知。
- Appium：本地产物、DUFS、通知。

因此网络故障时可能已产生部分远程结果。重试不能简单重跑整条流水线并再次覆盖生产包。

## 9. 自动化接入前必须处理的问题

| 问题 | 当前影响 | 系统处理要求（建议，未实现） |
| --- | --- | --- |
| 构建与发布耦合 | 普通执行自动上传和发通知 | 独立 build/archive/publish/notify；外部写入阶段明确授权 |
| Android debug 签名 | 新机器可能无法覆盖现网安装 | 核实现网指纹，接入正确密钥与签名校验 |
| SDK 参数无效 | 页面选择版本与真实编译版本不符 | 从项目锁定配置解析，并记录实际版本；不暴露无效选择 |
| proxy define 无消费者 | 文件名带代理但应用不一定使用 | 不标记为已生效；补齐业务实现后才开放 |
| validate-only 不完整 | 非法 type 也通过 | 服务端严格白名单和跨字段校验 |
| Shell set -e 与事后 `$?` 混用 | 某些“失败后警告继续”分支实际到不了；ERR trap 也不保证清理 | 显式阶段结果与错误处理；失败日志先保留再清理 |
| 缺产物只 echo 警告 | Flutter 返回 0 但指定文件不存在时，Shell 仍可能最终成功 | 校验文件存在、非空、包格式、包内版本和签名 |
| DUFS 只看 curl 退出码 | HTTP 错误可能误报成功 | 明确接受状态码，并核验远端大小或校验和 |
| 同名覆盖 | 日期/版本相同任务相互覆盖 | 任务 ID、Git SHA、构建号构成不可变归档路径 |
| 共享工作区 | 输出和生成代码、Rust 缓存发生并发冲突 | 每任务独立检出；共享下载缓存加锁或隔离 |
| 凭据硬编码及回退 App 凭据 | 缺少独立发布身份和权限边界 | 服务端凭据引用、日志脱敏；确认权限后迁移/轮换 |
| 配置值拼进 shell / eval | 不适合直接接受网页自由文本 | 参数枚举和进程 argv；不允许用户输入任意命令/代理 shell 片段 |
| iOS 导出配置缺失 | 无法保证可安装 IPA | 补齐团队、证书、profile、export method，真机构建安装验证 |

DUFS 和 Webhook 常量在脚本内直接赋值，不能以为同名环境变量已可覆盖。现有可用的 OSS 环境变量也没有通用凭据引用机制或显式 STS token 参数。

## 10. 独立打包系统的最小数据契约（建议）

以下为新系统字段建议，不是当前脚本已支持的 API。

### 10.1 任务输入

| 字段 | 含义与校验 |
| --- | --- |
| projectId / gitRef | 项目和分支/tag/commit；启动后解析并锁定 commit SHA |
| recipe | 固定配方；例如 shell-test-prod、fastlane-qc-debug；配方定义完整矩阵，避免任意字段组合 |
| platform / artifactType | android: apk/aab；ios debug: app.zip；ios release: ipa；受已验证能力约束 |
| environment / buildMode / showUme | 从配方推导；UI 展示实际值，不根据标签猜测 |
| versionName / buildNumber | 默认读 pubspec；若允许覆盖，需新增 Flutter 参数传递能力，现有入口未提供 |
| flutterVersion | 默认读 .fvmrc；执行前核验实际版本 |
| signingCredentialRef | 服务端签名凭据引用，不接受浏览器传入明文密钥 |
| buildProxyRef | 构建机网络代理配置引用；与 App 代理分开 |
| archiveTargets | 本地、DUFS、OSS 等；需要先拆分现有流程才能选择 |
| publishVersionAlias | 默认 false，仅验证通过的正式配方允许；以版本号控制并发 |
| notify | 默认独立选择；发送结果不改变编译结果 |

第一期配方可以直接映射已有 lane；暂不添加复杂插件框架。预生产、AAB、iOS 在对应路径实测后再开放。

### 10.2 阶段与结果

建议阶段：排队、检出、环境预检、依赖准备、检查、代码生成（按配方）、编译、产物校验、本地归档、远程上传、正式发布、通知、完成。

每阶段记录开始/结束时间、退出码、状态和日志。整体状态至少能区分：编译失败、编译成功但上传失败、上传成功但通知失败、全部成功、取消。取消时终止子进程，保留已完成阶段；不得默认删除已上传对象。

manifest 至少包含：taskId、commit SHA、是否有源码变更、recipe、真实 SDK/JDK/Gradle/Rust 版本、环境与 defines、包名、versionName、buildNumber、签名指纹、文件大小、SHA-256、本地产物路径、远程对象 key、可下载 URL、每阶段状态。日志不能记录明文凭据。

### 10.3 发布和重试

编译重试使用独立工作区；上传/通知重试复用已校验的同一文件，不重新编译。归档对象不可变；生产版本别名更新需串行化、记录旧对象及新文件校验和。版本接口发布另设集成点，待明确后端 API 后实施，不能凭空构造。

## 11. 调用示例与验证边界

下列完整构建命令会触发上传和钉钉，仅在发布目标和授权明确时执行；本次未执行：

```bash
# Shell：项目根目录，QC release APK，UME 关闭
bash build_handhelp_pos.sh --platform android --type test-prod --format apk

# Shell：预生产 release APK，UME 开启
bash build_handhelp_pos.sh --platform android --type pre-prod --format apk

# Fastlane：先进入项目 android 目录，准备已锁定 Ruby 依赖
bundle install
bundle exec fastlane android qc_debug
```

本次已完成：

- 完整读取两套构建入口，核对环境消费者、代理消费者、平台工程、资源生成、Appium 入口与更新下载逻辑。
- `bash -n build_handhelp_pos.sh` 通过；`ruby -c android/fastlane/Fastfile` 通过。
- 仅执行 Android AAB 的 validate-only，验证非法 type 和无效 SDK 仍被接受；未触发 SDK 安装、编译或外部写入。
- GitNexus 绑定 flutter-hpos；索引报告落后 5 个提交。按规则执行 `npx gitnexus analyze`，因 npm 报错 `Cannot destructure property 'package' of 'node.target' as it is null.` 失败。图查询仅辅助定位，本文行为结论均由当前源码复核。

未验证：真实构建是否通过、有效 Gradle 配置的运行日志、APK 签名与现网一致性、iOS 签名/导出名/安装、远程可达性及权限、文件上传后的完整性、钉钉投递结果。语法检查通过不等于发布流程可用。

系统上线前的验收重点：干净构建节点；每种开放配方的包内环境/版本/签名；401/500、超时、缺产物时正确失败；同版本并发不互相覆盖；生产别名仅正式任务更新；上传和通知可独立重试；iOS 若开放则需真机安装证据。
