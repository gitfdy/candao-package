# Android / iOS 打包脚本解析与统一平台接入契约

核验日期：2026-09-23；源码基线：`374ab5a`。当前工作区另有依赖锁文件改动。本文件根据脚本与环境选择代码核对，供后续打包系统实现使用；不表示平台功能已经实现。

范围：本会话涉及的 Android APK/AAB、iOS IPA、分发通知及相关 Shorebird 入口。Windows 构建不在本次范围。文中路径均相对仓库根目录，命令默认从仓库根目录执行，另有说明除外。只解析脚本，未执行上传、通知或热更新。

## 1. 接入结论

平台第一阶段应复用 `scripts/flutter_build.sh` 构建 Android，使用受控的 `fvm flutter build ipa` 构建 iOS。平台显式生成环境与 UME 参数，并独立管理归档、上传、通知。

不要直接把 `build_android_tappo.sh` 或 Fastlane 公共 lane 当作“只打包”接口：多数入口自带上传和通知。旧脚本的名称、日志提示及 OSS 目录名不保证等于运行环境。

需要分开的概念：

| 维度 | 示例 | 决定什么 |
| --- | --- | --- |
| 目标平台 | android / ios | 工具链与签名体系 |
| Flutter 编译模式 | release / debug | 优化、断言及调试能力 |
| 业务环境 | qc / beta / gray / release | API、默认 WebView、管理页地址 |
| UME 开关 | true / false | 调试菜单与已注册测试工具 |
| 包格式 | apk / aab / ipa | 安装或商店分发形式 |
| 渠道 | office / store | Android 应用内下载安装权限 |
| iOS 导出方式 | app-store-connect 等 | 签名及可用分发途径 |
| 发布操作 | 仅归档 / 上传 / 通知 / 补丁 | 是否修改外部系统状态 |

## 2. 入口清单与执行链

| 文件 | 职责 | 执行位置与副作用 |
| --- | --- | --- |
| `scripts/flutter_build.sh` | 设置隔离 Gradle Home，执行 `fvm flutter "$@"` | 自动切至根目录；无内置上传通知 |
| `scripts/build_android_tappo.sh` | Android 参数解析、构建、改名、DUFS/OSS 上传、钉钉 | 应从根目录执行；多数类型含外部动作 |
| `scripts/build_release_and_qc.sh` | 顺序调用 release、test-prod | 继承两次构建与分发动作；第二包并非显式 QC |
| `scripts/upload_oss.sh` | 复制为固定名称并上传 OSS | 读取 `scripts/oss_config.sh`，强制覆盖远端同名对象 |
| `ios/fastlane/Fastfile` | iOS 编译、签名导出、TestFlight、通知、Shorebird | 通常在 `ios/` 运行 `bundle exec fastlane ios <lane>` |
| `ios/fastlane/flutter_build.sh` | 清除 Ruby/Bundler 变量，执行指定程序 | 自动切至根目录；第一参数必须是单个可执行程序路径/名称 |
| `ios/fastlane/Appfile` | Bundle ID、Apple ID 配置 | Apple ID 来自环境变量 |
| `scripts/generate_changelog.rb` | 读取 Git 历史生成摘要，可创建 BUILD 标签 | Android 调用不创建标签；iOS 请求创建本地标签，无自动推送 |

Android 包装器链：参数 → 设置 `android/.gradle-home` → 切根目录 → FVM → Flutter → Gradle → APK/AAB。

Android 高层脚本链：解析类型/代理/格式 → 配置参数 → Flutter 或 Shorebird → 复制产物 → DUFS → 钉钉 → 部分 APK 另上传 OSS。

iOS 常规 lane 链：`flutter_setup`（默认 clean + pub get）→ `build ios --release` → Fastlane `build_app` 归档导出 → TestFlight → changelog/本地 BUILD 标签 → 钉钉。

## 3. Android 高层脚本参数与真实行为

### 3.1 参数

| 参数 | 默认值 | 当前行为 |
| --- | --- | --- |
| `--type/-t` | debug | debug、test-prod、release、release-devtools、shorebird、shorebird-test-prod |
| `--proxy/-p` | none | 1、2、none；普通构建的 1/2 注入 `proxy_type` |
| `--format/-f` | apk | 代码仅判断是否为 aab，其他值进入 APK 分支；平台必须先校验 |
| `--flutter-version/-v` | 3.41.0 | 只用于 Shorebird；普通构建由 FVM 决定版本 |
| `--help/-h` | 无 | 显示帮助 |

代理 1 对应 `192.168.220.57:9091`，代理 2 对应 `192.168.225.34:8888`，这是现有内网预设，不是任意代理接口。脚本没有通用 `--build-env`、`--no-upload`、版本号覆盖参数。

### 3.2 构建类型矩阵

| type | 模式 | Dart define | 实际默认业务环境 | UME | 分发 |
| --- | --- | --- | --- | --- | --- |
| debug | debug | 无环境参数 | QC，可受历史偏好影响 | 开 | DUFS + 钉钉 |
| test-prod | release | `test_production=true` | Beta，可受历史偏好影响 | 开 | DUFS + 钉钉；APK 另传 OSS qc 目录 |
| release | release | 无环境参数 | Release | 关 | DUFS + 钉钉；APK 另传 OSS release 目录 |
| release-devtools | release | `enable_dev_tools=true build_env=release` | 显式 Release | 开 | 跳过上传和通知 |
| shorebird | release | 无业务环境参数 | Release | 关 | Shorebird 注册 release、DUFS、钉钉 |
| shorebird-test-prod | release | `test_production=true` | Beta，可受历史偏好影响 | 开 | Shorebird 注册 release、DUFS、钉钉 |

所有 APK 添加 `channel=office` 与 Gradle `officeChannel=true`；AAB 不添加。普通 Flutter 代理参数来自 `BUILD_PARAMS`；Shorebird 分支重新组装命令，没有使用其中的代理设置，所以不能认为选择了代理就已经生效。

`build_release_and_qc.sh` 忽略外部 `--type`，其他参数转发两次，依次打 release 与 test-prod。它虽然启用 `set -e`，但只能依据子脚本退出码，不能补救子脚本漏报上传失败的问题。

### 3.3 输出

- Flutter APK：`build/app/outputs/flutter-apk/app-release.apk`，debug 对应 `app-debug.apk`。
- Flutter release AAB：`build/app/outputs/bundle/release/app-release.aab`。
- 高层脚本归档：`build/outputs/tappo_<YYYYMMDD>_v<版本名>_<类型>_<代理>.apk|aab`；Shorebird 增加 `shorebird_` 前缀。
- 版本名取自 `pubspec.yaml`，文件名删除了 `+buildNumber`；同日同配置可能覆盖。
- OSS 对象名取工作区目录名：`<目录名>-android.apk` 或 `<目录名>-android-qc_test.apk`。平台若使用随机 checkout 目录名，远端名称也会跟着变。

## 4. iOS Fastlane 解析

### 4.1 常规 lane

在 `ios/` 目录执行。以下现有入口全部会上传 TestFlight，并尝试生成标签、发送钉钉通知：

| lane | build_env | enable_dev_tools | 导出 |
| --- | --- | --- | --- |
| `release` | release | false（不传 true） | app-store |
| `release_debug` | release | true | app-store |
| `test` | qc | true | app-store |

`build_and_upload` 是私有 lane。公共常规 lane 将环境写死，并不是通用 `build_env` CLI 接口。签名为 automatic，team 取 `TEAM_ID`，未设置则用脚本中的项目团队。导出允许 provisioning 更新，意味着可能与 Apple 签名服务交互。

常规 IPA 命名：`tappo_<日期>_v<版本名>_<环境>[_devtools].ipa`。

**路径注意**：Fastfile 的 `__dir__` 为 `ios/fastlane`，`File.expand_path("../build/outputs", __dir__)` 实际是 **`ios/build/outputs`**，不是根目录 `build/outputs`。直接 `flutter build ipa` 的输出则是根目录 `build/ios/ipa`。

### 4.2 辅助方法

- `flutter_setup` 默认执行 clean、pub get。缓存会被清理，不应与另一任务共享工作区。
- `get_fvm_flutter_path` 检查旧格式 `.fvm/fvm_config.json`，在几个固定安装路径寻找 Flutter；找不到返回字符串 `fvm flutter`。
- `ios/fastlane/flutter_build.sh` 使用 `exec "$FLUTTER_CMD" $BUILD_ARGS`，因此回退字符串 `fvm flutter` 会被当成一个程序名；空格路径和参数分词也存在限制。平台应自行解析 SDK 的实际可执行路径，不依赖该回退。
- API Key 输入为 `APP_STORE_CONNECT_API_KEY_KEY_ID`、`APP_STORE_CONNECT_API_KEY_ISSUER_ID`、`APP_STORE_CONNECT_API_KEY_KEY`。最后一个是私钥文件路径，不是私钥内容；相对路径按 `ios/fastlane` 解析。不完整时回退 Apple ID。
- `upload_to_testflight` 设置 `skip_waiting_for_build_processing=true`、`skip_submission=true`：不会等待 Apple 处理完成，也不代表构建已可供测试。
- `upload_testflight_resilient` 对包含 `WILL RETRY`、`network connection was lost` 或 `-1005` 的异常告警后继续。平台必须将此结果标为“上传待核实”，不能据后续成功日志宣称 TestFlight 成功。

### 4.3 Shorebird

| lane | 行为与参数 |
| --- | --- |
| `release_shorebird` | `flutter_version` 默认 3.41.0，`build_env` 默认 release；Shorebird 生成无签名 archive，再导出并上传 TestFlight |
| `release_shorebird_qc` | 显式 QC + UME，临时使用 `shorebird_qc.yaml`，导出并上传 TestFlight |
| `patch_ios` | `env` 默认 release，`release_version` 默认 latest；直接下发补丁 |
| `patch_ios_qc` | 调用 patch_ios，强制 env=qc，版本默认 latest |

补丁必须匹配对应 release 的 Dart define 与 Shorebird app。不能只改变 API 环境就认为热更新已隔离：普通 `release_shorebird build_env:qc` 不会自动切 QC app 配置。

`with_shorebird_yaml` 临时覆盖根目录配置，ensure 中用 `git checkout -- shorebird.yaml` 恢复 HEAD，**不是恢复用户调用前的未提交内容**。因此只在独立、干净工作区使用；不并发执行。平台应显式指定补丁目标版本，不沿用 latest；未知 env 当前会进入生产分支，必须先做白名单校验。

## 5. 环境与 UME 的源码契约

来源：`lib/main.dart`、`lib/core/application/app_bootstrap.dart`、`lib/core/config/env_config.dart`、`android/app/build.gradle`。

- `main` 读取 `enable_dev_tools`、`test_production`，保存到 Application。
- UME 显示条件为 `kDebugMode || isTestProduction || enableDevTools`；工具注册使用同样条件。
- 无 UME 的推荐配置是 release 编译 + 两个布尔 define 都显式 false。debug 构建即使传 false 仍会开启 UME。
- `GlobalEnvironmentStep` 优先解析 `build_env`，EnvConfig 默认值也优先解析它。建议始终显式传入合法值，不依赖默认或历史存储。
- QC 默认 API/Web 域名为 `ab-v6-qc-tappo.can-dao.com`；Beta 为 `ab-v6-beta-tappo.can-dao.com`；Gray 为 `pos-verify.gotappo.com`；Release 为 `pos.gotappo.com`。
- 调试/UME 模式允许自定义或本地 WebView URL 覆盖默认地址。显式 build_env 不等于禁止运行时修改环境。
- office APK 必须成对传 `channel=office`、`officeChannel=true`；后者控制保留安装权限。商店 AAB 不传这两个参数。

## 6. 推荐的“仅构建”命令模板

以下普通 Flutter 模板不包含上传、通知、打标签或 Shorebird release。

### Android QC + UME

```bash
bash scripts/flutter_build.sh build apk --release \
  --dart-define=build_env=qc \
  --dart-define=enable_dev_tools=true \
  --dart-define=test_production=false \
  --dart-define=channel=office \
  --android-project-arg=officeChannel=true
```

### Android 生产、不启用 UME

```bash
bash scripts/flutter_build.sh build apk --release \
  --dart-define=build_env=release \
  --dart-define=enable_dev_tools=false \
  --dart-define=test_production=false \
  --dart-define=channel=office \
  --android-project-arg=officeChannel=true
```

商店 AAB：将 `build apk` 改成 `build appbundle`，移除 office 两个参数。版本覆盖使用 Flutter `--build-name`、`--build-number`，并同步记录实际产物版本，不能继续只从 pubspec 推断。

### iOS QC + UME

在任务独立目录生成 `ExportOptions.plist`（下面以当前项目团队为例，平台改为项目配置）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>PC4A7P943C</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>stripSwiftSymbols</key><true/>
  <key>uploadSymbols</key><false/>
</dict></plist>
```

```bash
BUNDLE_GEMFILE="$PWD/ios/Gemfile" bundle exec fvm flutter build ipa --release \
  --dart-define=build_env=qc \
  --dart-define=enable_dev_tools=true \
  --dart-define=test_production=false \
  --export-options-plist="$PWD/ExportOptions.plist"
```

生产无 UME：将环境改为 release、enable_dev_tools 改为 false。iOS 不传 Android office 参数。App Store Connect 导出不等于上传；导出的 IPA 不能直接侧载安装。Ad Hoc/开发分发需匹配证书、描述文件与注册设备，不可仅更改文件扩展名。

直接 Flutter 输出：`build/ios/archive/Runner.xcarchive`、`build/ios/ipa/*.ipa`。不要假定 IPA 基础文件名永远是 tappo；应枚举本次新产物并验证 Bundle ID。

## 7. 构建机与秘密配置

| 项目 | 当前配置/要求 |
| --- | --- |
| Flutter | `.fvmrc`：3.41.0；使用 FVM |
| Android | SDK 36、NDK 28.2.13676358、AGP 8.11.1、Gradle 8.14、Kotlin 2.1.0 |
| Java | 使用与 AGP/Gradle 兼容的 JDK；本会话 doctor 显示实际 Flutter 配置为 JDK 17 |
| iOS | macOS + Xcode；本会话实际使用 Xcode 26.6，最低部署 iOS 15 |
| Ruby | Bundler 按 `ios/Gemfile.lock` 安装；CocoaPods 1.16.2 |
| Android 签名 | `android/key.properties`：storeFile、storePassword、keyAlias、keyPassword，以及 keystore |
| iOS 签名 | 证书及私钥/可用自动签名身份、团队、provisioning profile |
| TestFlight | App Store Connect API Key 或受控 Apple ID 会话，按项目隔离 |
| Shorebird | CLI、匹配 app 配置及发布凭据（CI 使用 SHOREBIRD_TOKEN） |
| OSS | OSS_ENDPOINT、OSS_ACCESS_KEY_ID、OSS_ACCESS_KEY_SECRET、OSS_BUCKET、OSS_PATH_RELEASE、OSS_PATH_QC |

Android 包装器在隔离目录未有配置时会复制全局 Gradle properties，平台应显式提供网络/代理配置，避免继承个人机器设置。签名文件、机器人 Webhook 和上传密码不得进入归档或前端日志。旧脚本有硬编码分发凭据，本文不复制；平台使用秘密引用注入。

## 8. 已发现的接入限制

| 当前实现 | 对平台的影响 | 接入处理 |
| --- | --- | --- |
| Android test-prod 标为 QC，但默认 Beta | 环境误分发 | 生成显式 build_env，不用旧名称映射 |
| 高层脚本混合打包与分发 | 只想打包也会写外部系统 | 独立构建、分发、通知阶段 |
| Android 使用 eval 拼命令；缺参 shift 无充分校验 | 输入不安全、缺参可能不能正常结束 | 参数白名单与 argv 数组，不透传任意命令 |
| curl 多处未用 HTTP 失败判定；通知未校验业务返回码 | HTTP 失败也可能显示成功 | 同时检查退出码、HTTP 状态、业务返回值 |
| Android 高层脚本无全局 set -e；复制/上传部分错误可被后续命令掩盖 | 退出码不足以证明成功 | 核验新文件、签名、哈希及上传回读 |
| Shorebird 产物缺失只打印警告 | 可能拿不到产物仍继续 | 缺文件直接失败 |
| OSS 使用固定名称和 `cp -f` | 覆盖历史包；工作区名称影响对象名 | 固定项目标识 + 唯一任务路径；另行管理 latest |
| iOS TestFlight 瞬时异常被容错放行 | 上传状态不确定 | 保留 UNKNOWN 状态并查询远端确认 |
| iOS FVM 路径回退与参数分词有限制 | 新机器可执行路径错误 | 平台使用 SDK 绝对路径 |
| Shorebird 配置恢复到 HEAD | 丢弃该文件未提交改动 | 干净独立工作区并禁止并发 |
| 日期+版本文件名不含构建号/任务号 | 重跑覆盖 | 每次任务独立归档 |
| 自动标签基于本地 Git 历史 | 不同 runner 的 changelog 边界不一致 | 平台明确上次成功发布 ref，标签独立管理 |

以上是源码分析所得；本次未修改这些行为，也未对上传服务进行探测。

## 9. 平台最小任务模型（建议，尚未实现）

输入示例：

```json
{
  "project": "tappo",
  "git_ref": "<commit-sha>",
  "platform": "android",
  "artifact": "apk",
  "mode": "release",
  "environment": "qc",
  "ume_enabled": true,
  "channel": "office",
  "version_name": "2.4.10",
  "build_number": 59,
  "signing_profile_ref": "<secret-profile-id>",
  "distribution": "none",
  "notify": false
}
```

约束：iOS 必须 IPA；Android APK/AAB；商店 AAB 不使用 office；`ume_enabled=false` 不配 debug；环境仅允许四个枚举。版本号按目标商店/升级要求校验，不复用已上传构建号。发布与通知权限独立于构建权限。

任务阶段：校验 → 获取独立源码 → 准备依赖和签名 → 编译 → 导出/签名 → 验证 → 归档 → 可选分发 → 可选通知。

编译失败可重新构建；导出失败且 archive 已验证时可单独重试导出。上传失败复用已归档哈希对应的包，不重新编译。通知失败不改变构建成功状态。TestFlight 上传成功、Apple 处理中、处理成功应分别记录。

产物元数据最少包括：taskId、源码 SHA、dirty、锁文件摘要、工具链版本、完整非敏感参数、环境、UME、渠道、版本名/号、Bundle ID/applicationId、签名标识、文件大小和 SHA-256、每阶段结果、警告、设备验收状态。

缓存按 Flutter/SDK/依赖锁等信息划分；每任务独立 `build/` 和临时配置，避免 Flutter clean、生成配置、Shorebird swap 相互干扰。取消任务需终止所属构建进程树，取消中的产物不发布。

## 10. 验证与验收

Android：用 SDK 的 `apksigner verify --verbose --print-certs` 校验签名，`aapt dump badging` 检查版本、包名、ABI、最低 SDK、debuggable 和权限。生产无 UME 的判断同时依赖 release 编译参数与源码开关，不能拿 debuggable=false 单独证明 UME 关闭。

iOS：解包后检查 Info.plist、embedded.mobileprovision、签名和 entitlements；核对最低 iOS、Bundle ID、版本、导出类型。必要时用 `codesign --verify --deep --strict` 验证。Generated.xcconfig 的 DART_DEFINES 可解码作为构建参数证据，但必须在同一任务结束时归档，避免下次构建覆盖。

所有产物要求：退出码正常、新产物时间匹配本次任务、文件非空、SHA-256 记录完整。上传后核验远端对象及内容摘要；不能仅判断脚本打印“成功”。

设备验收：QC 默认请求域名、UME 菜单是否出现、生产无调试入口、安装升级、冷启动、系统深浅切换。签名检查和单元测试不替代设备验收。

本会话已完成普通 Flutter Android QC+UME、Android 生产无 UME、iOS QC+UME 构建及签名核验，版本均为 2.4.10+59；均未上传、未做真机验收。现存 iOS 警告为 UIScene 迁移提示和启动图占位；依赖升级提示不在本任务修复范围。Shorebird/DUFS/OSS/TestFlight 的实际发布链本次仅静态解析，未执行验证。

## 11. 源码索引

- 构建入口：`scripts/flutter_build.sh`、`scripts/build_android_tappo.sh`、`scripts/build_release_and_qc.sh`。
- 上传与通知：`scripts/upload_oss.sh`、`scripts/oss_config.sh`、`scripts/generate_changelog.rb`。
- iOS：`ios/fastlane/Fastfile`、`ios/fastlane/flutter_build.sh`、`ios/fastlane/Appfile`、`ios/Gemfile`。
- 运行契约：`lib/main.dart`、`lib/core/config/env_config.dart`、`lib/core/application/app_bootstrap.dart`、`lib/core/application/application.dart`。
- 签名与工具链：`.fvmrc`、`pubspec.yaml`、`android/app/build.gradle`、`android/settings.gradle`、`android/gradle/wrapper/gradle-wrapper.properties`、`ios/Runner.xcodeproj/project.pbxproj`。
- 原 Android 专项说明：`docs/build/android_build_script_tappo.md`。统一平台接入以本文为总入口，旧说明不替代实际源码。
