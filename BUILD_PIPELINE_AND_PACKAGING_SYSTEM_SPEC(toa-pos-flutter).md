# 打包脚本解析与独立打包系统接入方案

> 核查日期：2026-09-23。源码基线：`feature/flutter-native-migration-followup@eb7f9024bd022fb02b65673fb264469a0629232c`。
> 当前应用版本：`4.0.6+25`；FVM 配置：Flutter `3.41.9`。
> 本文根据仓库源码梳理。命令示例未执行构建、上传、发布、安装或通知。Windows BAT/PowerShell/Inno Setup 尚未在 Windows 工作机执行验证。
> “现有行为”描述当前代码；“建议”是未来打包系统要求，不能视为脚本已具备的能力。

## 1. 接入结论

现有主要入口是 Android 的 `scripts/build_android.sh` 和 Windows 的 `scripts/build_windows.bat`；更新元数据统一由 `tool/publish_version_config.dart` 处理。脚本同时承担构建、安装器生成、Shorebird 发布和 OSS 发布，不能直接把一个命令的退出码当作完整发布结果。

建议新系统拆成：锁定源码 → 准备依赖 → 构建/创建基线 → 校验产物 → 生成安装器 → 上传产物 → 发布更新配置 → 通知。每个阶段独立记录结果，发布需要显式选择。优先复用现有 Dart 发布工具及 manifest 生成器，逐步收敛脚本入口。

尤其注意：

- Windows `release`、`shorebird-test-prod` 默认 `--local false`，会上传 OSS 并更新 latest.json；即使指定 `--local true`，仍调用 Shorebird release，不能当成完全无外部写入的本地构建。
- Android 不指定 `--publish-artifact` 时不写 OSS，但 `release`、`shorebird`、`shorebird-test-prod` 仍会执行 Shorebird release。
- `test-prod` 是 release 模式的测试生产环境包，不是 Shorebird 基线；`shorebird-test-prod` 才表示建立独立热更新基线的意图。
- 当前 Android Test-Prod Shorebird 实现有配置隔离缺口，接入前必须修复或禁用该任务类型，详见第 10 节。

## 2. 脚本清单与推荐定位

| 入口 | 当前职责 | 系统接入建议 |
| --- | --- | --- |
| [build_android.sh](/Users/dylan/Desktop/candao/toa-pos-flutter/scripts/build_android.sh) | Android APK/AAB、Shorebird 基线、可选 OSS 发布 | Android 主入口，先处理参数和 Test-Prod 隔离问题 |
| [build_windows.bat](/Users/dylan/Desktop/candao/toa-pos-flutter/scripts/build_windows.bat) | Windows 构建、DLL、Inno 安装器、OSS、Shorebird 基线/补丁 | Windows 主入口，拆开构建和发布阶段 |
| [build.bat](/Users/dylan/Desktop/candao/toa-pos-flutter/build.bat) | 人工菜单，转调 Windows 主脚本 | 不作为无人值守入口；菜单“test-prod 上传”不符合当前主脚本发布条件 |
| [build_windows_new.bat](/Users/dylan/Desktop/candao/toa-pos-flutter/scripts/build_windows_new.bat) | 构建 runner 或接受制品目录，打印路径即退出 | 名称虽为 new，但没有完整安装器/发布流程；`--local` 未用于实际动作 |
| [build_release.bat](/Users/dylan/Desktop/candao/toa-pos-flutter/build_release.bat) | 另一套 Windows release 构建，`--env qc/prod`，静态 installer.iss | 历史入口；有清理、交互、相邻插件切分支及硬编码路径，不直接接入 |
| [build_from_artifacts.bat](/Users/dylan/Desktop/candao/toa-pos-flutter/scripts/build_from_artifacts.bat) | 已编译目录生成安装器，可上传旧 DUFS 并通知 | 可参考“制品再包装”逻辑；须剥离旧凭据与上传逻辑 |
| [ssh_build_windows.bat](/Users/dylan/Desktop/candao/toa-pos-flutter/scripts/ssh_build_windows.bat) | 面向 SSH 终端的 Windows 本机构建/安装器/旧上传流程 | 本身不建立 SSH 连接；不要误作跨主机调度器 |
| [publish_shorebird_patch.sh](/Users/dylan/Desktop/candao/toa-pos-flutter/scripts/publish_shorebird_patch.sh) | Android/Windows 补丁，默认 Android | Bash 补丁入口；Test-Prod 配置隔离待处理 |
| [publish_shorebird_patch.bat](/Users/dylan/Desktop/candao/toa-pos-flutter/scripts/publish_shorebird_patch.bat) | 默认 Windows 的正式补丁入口 | 与主脚本 patch 参数不完全相同，见第 6 节 |
| [invoke_shorebird_patch.ps1](/Users/dylan/Desktop/candao/toa-pos-flutter/scripts/invoke_shorebird_patch.ps1) | 验证参数并以参数数组调用 Shorebird | Windows 补丁命令封装，可复用 |
| [publish_version_config.dart](/Users/dylan/Desktop/candao/toa-pos-flutter/tool/publish_version_config.dart) | prepare / publish / rollback | 建议保留为唯一 OSS 发布实现 |
| [generate_incident_build_manifest.dart](/Users/dylan/Desktop/candao/toa-pos-flutter/scripts/generate_incident_build_manifest.dart) | 生成带 Git SHA 的 Base64 构建身份 | 两平台复用；PS1 负责 Windows 环境变量适配 |

辅助脚本包括 `get_version.bat`、`copy_octopus_dll.bat`、`copy_vcruntime_dlls.bat`、`copy_debug_dlls.bat`、`validate_installer.bat`、`check_build_environment.bat`、`clean_build_env.bat`。环境检查/清理工具不等于正式流水线的自动门禁。

## 3. 工作机与源码准备

### 3.1 共用要求

- 固定 Git commit；保存分支、完整 SHA、锁文件摘要和工具版本。manifest 只读取 HEAD，不验证工作树干净；新系统必须自行拒绝不明 dirty 工作树。
- 在项目根目录执行。Android 主脚本虽计算 PROJECT_ROOT，但未 `cd`，pubspec、tool 和输出路径仍依赖调用目录。Windows 主脚本会回到项目根目录。
- 准备 `.fvm/flutter_sdk`，使用 `.fvmrc` 的 `3.41.9`；Shorebird 的 `--flutter-version` 另行控制其构建版本，需记录实际使用版本，不只记录参数。
- 先执行 `fvm flutter pub get`。Android manifest 生成器依赖 package:crypto，干净检出若未解析依赖，会在正式 build 前失败。Windows 主脚本已在生成 manifest 前执行 pub get。
- 私有 Git 依赖需只读拉取权限：flutter_uvc_camera、octopus_payment_flutter、kpay；nsd_windows 来自固定 Git revision。以 pubspec.yaml 和 pubspec.lock 为准，不用旁边某个插件分支替代。
- 每个任务独立 checkout/工作目录。Windows 临时 ISS、build、version.tmp 和 Shorebird YAML 切换存在共享路径，不能在同一 checkout 并发打包。

### 3.2 Android 工作机

Bash、FVM/Dart、Android SDK、JDK 17、Gradle 所需 NDK，以及本地 AAR/JAR/Maven 仓库。当前 app 配置：compileSdk 36、minSdk 24、targetSdk/NDK 跟随 Flutter，AGP 8.11.1、Kotlin 2.2.20。

必须检查 `android/app/libs`、`android/local-repo` 的实际文件及校验值，尤其八达通、商米、USB 摄像头依赖；本机未跟踪文件不代表干净 CI 节点具备同样依赖。不能将 `android/build` 缓存当作依赖交付。

### 3.3 Windows 工作机

Windows x64、Visual Studio C++ Desktop 工具链及 Windows SDK/CMake、PowerShell、FVM、Inno Setup 6。主脚本默认 ISCC 路径为 `C:\Program Files (x86)\Inno Setup 6\ISCC.exe`；Shorebird 默认查找 `%USERPROFILE%\.shorebird\bin\shorebird.ps1`。

运行目录必须包含 EXE、Flutter/插件 DLL、数据目录和 native assets。八达通 `ocrl.dll/lrw.dll` 来自 `assets/dll`；VC runtime 复制脚本依赖系统 DLL 位置。缺 DLL 当前可能仅警告，新系统必须增加清单核验。

## 4. 环境、模式与参数

### 4.1 运行环境实际判定

[main.dart](/Users/dylan/Desktop/candao/toa-pos-flutter/lib/main.dart:500) 的优先级：

1. `test_production=true` 或启动参数 `--test-production`：`Environment.testProduction`。
2. 否则 release 模式：production。
3. 否则 profile 模式：staging。
4. 否则：development。

因此，旧脚本把 QC 描述为 test-prod 不代表运行时选择 staging。新系统应分别存储 `buildMode`、`runtimeEnvironment`、`updateChannel`、`shorebirdAppId`，不能只存“测试/正式”。

### 4.2 构建类型矩阵

| 平台 / type | 引擎命令 | 运行环境 | OSS 行为 |
| --- | --- | --- | --- |
| Android debug | fvm flutter build apk/appbundle --debug | development | 不允许发布全量更新 |
| Android test-prod | fvm flutter build … --release + test_production | testProduction | 不允许通过主脚本发布 |
| Android release / shorebird | shorebird release | production | 仅 `--publish-artifact` 时上传并发布 |
| Android shorebird-test-prod | shorebird release + test_production | testProduction | 同上，但当前 YAML 隔离缺陷需先修复 |
| Windows debug | flutter build windows --debug | development | 不发布 |
| Windows test-prod | flutter build windows --release + test_production | testProduction | 不发布，即便 `--local false` |
| Windows release-debug | flutter build windows --release + enable_debug_tool | production | 不发布；不是 debug 引擎 |
| Windows release | shorebird release windows | production | 默认发布；`--local true` 仅跳过 OSS |
| Windows shorebird-test-prod | 切换 YAML 后 shorebird release windows | testProduction | 默认发布到 test-production；local true 跳过 OSS |
| Windows shorebird-*-patch | patch 分支 | 跟随对应基线和 defines | 不生成安装器/OSS latest，发布 Shorebird 补丁 |

### 4.3 Android 主入口参数

| 参数 | 默认值 / 可选值 | 说明 |
| --- | --- | --- |
| `--type/-t` | debug；test-prod/release/shorebird/shorebird-test-prod | 必须由系统做枚举验证 |
| `--format/-f` | apk；aab | OSS 全量更新只支持 APK；当前脚本非 aab 值可能落入 APK 分支 |
| `--proxy/-p` | none；1/2 | 应用运行时代理，不是 Gradle/依赖下载代理 |
| `--flutter-version/-v` | 3.41.9 | Shorebird 构建用 |
| `--config-url` | 按环境选默认 URL 或 TOA_OSS_* 环境变量 | 编译进应用的更新配置入口 |
| `--publish-artifact` | false，出现即 true | 上传 APK，再改 latest.json |
| `--first-publish` | false | 首次创建平台配置；不能当作普通重试开关 |
| `--metadata-output` | build/outputs/android-release-metadata.json | 发布元数据文件 |
| `--force-update` | false；true/false | 全量升级强制提示策略 |
| `--release-note` | 无；可重复 | 逐条说明，不拼成一条 shell 命令 |

### 4.4 Windows 主入口参数

| 参数 | 默认值 / 可选值 | 说明 |
| --- | --- | --- |
| `--type/-t` | debug；见矩阵 | 主入口不支持 AAB/APK |
| `--proxy/-p` | none；1/2/3 | 3 已在解析中支持，即使部分帮助文案未列出 |
| `--local/-l` | false | 只约束全量 OSS 发布，不禁止 Shorebird release/patch |
| `--config-url`、`--flutter-version` | 环境 URL、3.41.9 | 含义同上 |
| `--metadata-output` | build/outputs/windows-release-metadata.json | 平台元数据 |
| `--force-update` | false | 只接受 true/false |
| `--first-publish` | false | 首次发布配置 |
| `--release-note` | 默认 4 条预设文案 | 自定义第一条会清空默认；最多 4 条；系统不应沿用过期预设说明 |
| `--release-version` | 当前 pubspec 完整版本 | Windows patch 目标，应由系统强制显式选择 |
| `--dry-run` | false；需传 true/false | 仅 patch 分支；不同于独立补丁脚本的无值开关 |

### 4.5 环境变量

| 变量 | 用途 / 约束 |
| --- | --- |
| `TOA_OSS_ANDROID_CONFIG_URL` / `TOA_OSS_WINDOWS_CONFIG_URL` | 正式应用更新配置 HTTPS URL |
| `TOA_OSS_TEST_PROD_ANDROID_CONFIG_URL` / `TOA_OSS_TEST_PROD_WINDOWS_CONFIG_URL` | 测试生产配置 URL |
| `TOA_OSS_CHANNEL` | production 或 test-production |
| `TOA_OSS_PREFIX` | 默认 toa-pos/通道；主脚本还使用 TOA_OSS_PRODUCTION_PREFIX / TOA_OSS_TEST_PROD_PREFIX |
| `TOA_OSS_BUCKET`（兼容 OSS_BUCKET） | 发布 bucket；工具预演 prepare 也要求此值 |
| `TOA_OSS_PUBLIC_BASE_URL` | 产物下载根 URL，默认 https://static2.gotappo.com |
| `TOA_OSS_ENDPOINT` / `TOA_OSS_REGION` | 默认香港 endpoint / cn-hongkong |
| `OSS_ACCESS_KEY_ID` / `OSS_ACCESS_KEY_SECRET` / `OSS_SESSION_TOKEN` | ossutil 身份；由凭据库注入，不入 Git/日志 |
| `TOA_INCIDENT_API_BASE_URL` | Windows 非 debug 主构建和 PS1 patch 必需；安全 HTTPS，不接受用户信息/query/fragment |
| `TOA_TEST_AUTOMATION_ENABLED` | 默认 false；正式构建禁止 true |
| `TOA_TEST_AUTOMATION_PORT` / `TOA_TEST_AUTOMATION_TOKEN_SHA256` | 显式启用时需 1–65535 和 64 位十六进制 SHA256 |
| `TOA_SHOREBIRD_PATCH` / `TOA_SHOREBIRD_BASE_SHA` | 补丁编号、40 位基线 Git SHA |
| `TOA_DINGTALK_WEBHOOK` | 主脚本通知函数读取，但主构建链没有调用该通知函数 |

Shorebird CLI 登录凭据也需由工作机凭据管理配置；这些脚本没有实现登录流程。不要把 OSS 凭据与 Shorebird 凭据混为一套。

默认更新地址为 `https://tappo.oss-cn-hongkong.aliyuncs.com/toa-pos/{production|test-production}/{android|windows}/latest.json`。应用内 config URL 与工具实际写入 bucket/prefix 是两条配置链，新系统必须验证二者对应同一对象；自定义 URL 不会自动修改发布目标。

代理真实映射在 main.dart：1 为 192.168.220.181:9090，2 为 192.168.225.34:8888，3 为 192.168.225.230:9090。Android 主脚本却把 1 命名为 192.168.220.57:9091，属于产物命名/帮助与实际运行行为不一致。

## 5. 全量构建与产物

### Android

参数解析 → 更新通道与代理 → 读取 pubspec 版本 → 校验自动化和 config URL → 生成 manifest → Flutter/Shorebird 构建 → 复制产物 → 可选 prepare/upload → publish/latest。

原始产物：

- APK：`build/app/outputs/flutter-apk/app-{debug|release}.apk`。
- AAB：`build/app/outputs/bundle/{debug|release}/app-{debug|release}.aab`；debug AAB 实际是否适合作为交付，不能只根据脚本分支认定支持。
- 收集产物：`build/outputs/[shorebird_]toa_pos_YYYYMMDD_v版本_环境_代理.apk|aab`，版本中的 `+` 替换为 `_`。

### Windows

参数/发布预检 → FVM/Dart 与 native_assets 目录 → pub get → patch 分支或完整构建 → manifest → 检查 ephemeral → Flutter/Shorebird → 同步 app.so → DLL → 临时 ISS → ISCC → 复制安装器 → 可选 OSS 发布。

- runner：`build/windows/x64/runner/{Debug|Release}`，EXE 名为 `toa_pos_flutter_temp.exe`。
- 主脚本要求 `build/windows/app.so` 并复制到 runner/data；对于 debug 构建，这个检查可能不适用，或误取上次 release 的 app.so，需 Windows 干净工作区验证。
- 安装器中间目录：`installer/output/`，根据类型命名 toa_pos_setup、toa_pos_setup_debug、toa_pos_setup_test_prod、toa_pos_setup_release_debug。
- 收集产物：`build/outputs/toa_pos_windows_YYYYMMDD_v版本_环境_代理.exe`。
- Inno AppVersion 使用语义版本，文件名/OSS/manifest 保留完整 `版本+buildNumber`。
- 文件名只有日期，缺少 taskId/commit；同日同版本同配置会复用目标路径。新系统应每任务独立归档，不依赖这个文件名保证唯一性。

### Windows 安装行为

主脚本生成 temp_installer.iss，不直接使用根 installer.iss。两者应分别审计，修改一份不保证另一份生效。

- 应用名 ABI POS，安装到当前用户 LocalAppData/Programs/ABI POS；基本安装权限为 lowest。
- Inno AppId 固定，各环境共享 AppId/目录，不能默认认为测试包与正式包可以并存。
- 强制关闭运行应用，默认不重启进程；结束页提供启动选项，静默安装跳过该选项。
- 引入 Windows 手写组件检查，缺能力时可请求管理员权限并安装。`/UPDATE=1` 的应用内升级跳过此预装步骤；3010 表示需重启再运行安装器。
- 手写组件结果等待循环未见总超时；失败/权限拒绝/离线 Windows 能力安装需独立验收。
- 卸载配置包含应用目录及 LocalAppData/ABI POS 清理。打包系统不要用“卸载再安装”作为默认升级验证，否则可能丢本地数据。

## 6. Shorebird 基线与补丁

当前两套 App ID：正式 `3bf0e471-6f71-4994-86a3-bf14f9bd9c92`，Test-Prod `94c500c6-0678-4e6e-9c5a-cefd4a3dbaea`。ID 是项目标识，不是登录凭据。

Windows 主脚本校验生产 shorebird.yaml；Test-Prod 将其备份，复制 shorebird_test_prod.yaml，命令结束后恢复并检查 ID。进程被强杀时恢复步骤可能不执行，因此必须隔离 checkout 并在下次任务重新验证配置。

独立 Bash patch 支持 `--platform android|windows`（默认 android）、`--track stable|beta|staging`、必填精确 `--release-version`、`--test-prod`、`--proxy 1|2|none`、无值 `--dry-run`。Windows 独立 BAT 默认 windows，当前只封装正式环境、proxy none；主 Windows 脚本才包含 Test-Prod patch 和更多代理参数。

补丁要求：精确基线版本、目标 App ID、补丁编号、基线 SHA、补丁 SHA、相同平台与关键编译参数。当前脚本并不验证填写的编号等于 Shorebird 服务端最终编号，新系统应采集远端结果核对。

`--dry-run` 是 Shorebird 校验流程，不代表离线执行；可能仍解析依赖、编译和访问服务。补丁不生成全量安装器，也不自动更新 OSS latest.json。OSS 配置回滚不等于已安装应用降级，更不等于 Shorebird 补丁回滚。

## 7. OSS 发布协议

### prepare

`fvm dart run tool/publish_version_config.dart prepare --platform android|windows --version 版本+构建号 --artifact 文件 --metadata-output 文件 [--upload]`

验证扩展名（Android APK / Windows EXE）与版本，计算 SHA256、字节数，生成平台元数据。不加 --upload 仅写本地 JSON；加 --upload 会禁止覆盖同 key，上传后回读校验内容，再验证公网可访问性。

对象结构：

```text
toa-pos/{channel}/
  {platform}/{version+build}/toa-pos-{platform}-{version_build}.{apk|exe}
  {platform}/latest.json
  {platform}/history/{UTC时间戳}.json
  {platform}/locks/latest.lock
```

元数据字段：platform、enabled、version、forceUpdate、artifact（url/sha256/sizeBytes/objectKey）、shorebird（enabled/track）、releaseNotes。prepare 默认 shorebird-enabled=true，非 Shorebird 产物若单独调用此工具，应显式 false，避免发布虚假热更新能力。

### publish

接受 `--android-metadata` 和/或 `--windows-metadata`。默认预演；只有 --publish 才改远端。现有配置不存在需 --first-publish；--base-config 与 first-publish 互斥，且 base-config 只能用于单平台。

每个平台单独生成包含 schemaVersion、channel、generatedAt、platforms 的 latest.json。发布先创建禁止覆盖的锁对象，保存原配置到 history，写 latest，回读解析与比对，最后删除锁。两个平台顺序执行，不是跨平台原子事务。

锁无 TTL/自动续租；进程中断可能遗留锁，需要受控恢复。当前读取旧配置在加锁之前，因此锁能防止同时写，但不能保证历史快照一定覆盖并发前最近一版。新系统应对 channel/platform 串行发布，并记录当前版本前置条件。

### rollback

`rollback --platform android|windows --history-key 对象key [--publish]`，校验历史通道、备份当前配置、写回目标平台并回读。只回滚更新指针；不卸载门店应用，也不撤销已应用的补丁。

## 8. 构建身份和任务数据模型（建议）

现有 manifest 是 `build-manifest.v1`，包含 appVersion、buildNumber、gitSha、platform、abi、buildType、artifactId、shorebirdAppId/Release/Patch、baseSha、patchSha，以及规范化 JSON 的 manifestHash。通过 `TOA_INCIDENT_BUILD_MANIFEST_B64` 编译注入；manifestHash 不是安装包 SHA256。

建议任务接口使用结构化参数，禁止用户输入任意 shell 片段：

```json
{
  "taskId": "build-0001",
  "gitCommit": "<完整40位SHA>",
  "platform": "windows",
  "operation": "build",
  "buildType": "test-prod",
  "flutterVersion": "3.41.9",
  "appVersion": "4.0.6",
  "buildNumber": 25,
  "proxyType": "none",
  "configUrl": "<已批准的HTTPS配置地址>",
  "publishArtifact": false,
  "publishConfig": false,
  "notify": false,
  "releaseNotes": [],
  "credentialProfile": "<凭据引用，不存密钥值>"
}
```

operation 建议枚举 build/package/release/patch/rollback；不同 operation 校验各自字段。patch 另需 releaseVersion、appId、track、patchNumber、baseSha。当前脚本从 pubspec 读取版本，不直接支持上述 appVersion/buildNumber 参数；系统要校验一致或先形成可追溯的版本变更，不能只改任务记录。

任务结果至少保存：Git SHA、dirty 判定、实际工具版本、脱敏后的 defines、所有阶段开始/结束/退出码、完整日志地址、runner 和安装器清单、产物 SHA256/大小、manifest、签名证书指纹、Shorebird Release/Patch 结果、OSS key/metadata/latest 快照、通知结果。

阶段失败后只重试失败阶段。例如 Shorebird release 成功但 ISCC 失败，记录“基线已创建、安装器失败”；不要直接重跑整条命令再次创建基线。

## 9. 参考任务调用

以下为未来工作机调用模板，本文未执行。先准备依赖与所需环境变量；不要把占位值直接发布。

```sh
# 项目根目录；本地 Android 测试生产 APK，不执行 OSS/Shorebird 发布
bash scripts/build_android.sh --type test-prod --proxy none --format apk

# 正式 Android：会创建 Shorebird Release；此例未开启 OSS 发布
bash scripts/build_android.sh --type release --proxy none --format apk
```

```bat
rem Windows 本地测试生产安装器；需配置 Incident HTTPS 地址
call scripts\build_windows.bat --type test-prod --proxy none --local true

rem Windows 正式安装器；仍会创建 Shorebird Release，仅不上传 OSS
call scripts\build_windows.bat --type release --proxy none --local true

rem Windows 补丁预演；先设置补丁编号、基线SHA、Incident地址
call scripts\build_windows.bat --type shorebird-release-patch --release-version 4.0.6+25 --dry-run true
```

要发布全量 OSS 时，Android 显式加 --publish-artifact；Windows release/shorebird-test-prod 使用 --local false。新系统应把这些行为转换成独立发布阶段，不直接暴露相反默认值。

## 10. 已确认风险与接入前整改

| 优先级 | 源码事实 / 风险 | 建议 |
| --- | --- | --- |
| P0 | Android shorebird-test-prod 只改 define/manifest App ID，未切换 shorebird.yaml；Bash patch 的 --test-prod 同样未切换 | 接入前核对/切换真实 CLI App ID并保证恢复；未修复前禁用此任务类型 |
| P0 | build_from_artifacts.bat、ssh_build_windows.bat 留有硬编码机器人令牌与上传账号口令 | 不复制到系统或文档；迁出到凭据管理、检查并轮换旧凭据；不要默认执行旧脚本 |
| P0 | Android release 仍使用 debug signing，applicationId 为 com.example.toa；未见 Windows 签名阶段 | 明确正式身份/升级兼容与签名责任，签名结果加入门禁，不擅自更改包名 |
| P0 | release 构建隐含 Shorebird 外部写入，Windows 默认还写 OSS | 创建基线、上传产物、发布 latest、通知分别授权和记录 |
| P1 | Android eval 拼接 BUILD_PARAMS，BAT delayed expansion 和自定义文案存在特殊字符风险；缺值参数验证不完整 | 系统侧枚举/类型/URL 白名单校验；执行器使用参数数组，严禁直接拼用户文本 |
| P1 | Android Shorebird 产物缺失只警告；普通 cp 失败也未立即检查，缺少 set -e | 退出码之外校验新产物存在、时间/版本/摘要，不允许旧文件冒充本次成功 |
| P1 | Windows debug 仍要求 release 风格 app.so；DLL 失败可继续 | 在全新 Windows checkout 测试每个 type，缺关键文件必须失败 |
| P1 | Android 没有 pub get 前置步骤；只检查本地 FVM Dart；普通构建与 Shorebird SDK 可能不同 | 准备依赖并核对实际 SDK/lockfile，工作机预检统一实现 |
| P1 | Windows/Bash patch 的 Incident defines 不一致，可能偏离基线 | 将基线 defines 固化并对比，补丁保持必要参数一致 |
| P1 | Android USB/UVC 预编译库历史检查有 6 个 4KB ELF，不满足 16KB 页兼容 | 执行 ELF 与 zip 对齐检查、取得兼容依赖后在目标设备验证；仅 zipalign 不够 |
| P1 | installer.iss 写死 D:\candao 路径；旧 build_release 清理工作区、要求相邻插件分支并可切分支 | 不纳入无人值守主入口；收敛可参数化安装器，不触碰用户 checkout |
| P1 | 固定临时文件/输出路径、YAML 临时覆盖、OSS 锁无过期 | 每任务工作区隔离；平台通道串行发布；失败恢复应核对锁 owner |
| P2 | Android proxy 1 命名不符真实地址；交互菜单 test-prod 上传失效；通知函数有定义无调用 | 修正文案和能力列表，通知作为独立可选阶段 |
| P2 | 当前日期命名、硬编码默认发布说明、无统一结构化结果 | 系统按 taskId/commit 归档，保存机器可读阶段结果 |

上表为源码审计结论，不表示本文已经修复这些脚本，也不表示所有构建类型均已实际执行失败。

## 11. 最小系统落地顺序与验收

1. 先做参数校验、独立 checkout、工作机分配、日志与产物归档；支持 Android test-prod APK、Windows test-prod EXE 的本地任务。
2. 加入可重复的签名/依赖/产物检查，验证干净节点、中文/空格路径、取消任务、缺 DLL 和失败退出。
3. 修复 Shorebird App ID 隔离与 compile defines 对齐后，接入基线和 patch dry-run；逐项验证正式/测试环境不会串用。
4. 复用 Dart 工具接入 prepare、独立上传、latest 发布和配置回滚；验证重复版本拒绝覆盖、锁冲突、上传成功而配置失败的恢复。
5. 最后加入通知、任务排队和多工作机。通知失败不应把已发布版本伪装成“构建失败”，也不应自动重发整个发布流程。

验收至少覆盖：Android APK/AAB 原始产物、Windows 完整 runner/EXE、正确环境与 config URL、版本/签名可覆盖升级、测试自动化正式禁用、基线/补丁归属、OSS 内容摘要/公网可达、Windows 安装手写能力及 UPDATE 跳过行为、无现场数据丢失的升级路径。

## 12. 本次核查边界

本次只读解析源码并创建本文；不执行脚本中的构建、上传、通知、安装、删除、切分支动作。Bash 语法检查与已有安装器/构建身份/发布工具测试用于辅助验证；不能替代 Windows BAT/Inno 执行、签名、Shorebird/OSS 真实联调。完整源码是当前行为的最终依据；脚本更新时应同步本文件和测试。

本次验证结果：

- `bash -n scripts/build_android.sh scripts/publish_shorebird_patch.sh`：通过。
- 使用项目 FVM Flutter 执行 `windows_installer_config_test.dart`、`build_manifest_test.dart`、`publish_version_config_test.dart`：25 项测试全部通过。
- 当前主机未执行 Windows BAT/Inno 安装流程，也未执行真实打包和发布；上述通过结果不代表所有构建类型已完成端到端验收。
