# 打包脚本解析与打包系统接入说明

> 审计日期：2026-09-23。本文描述当前源码行为，并单独标明新系统建议；不是已经实现的打包系统接口。
> 本次只做静态调查和文档整理，没有执行构建、上传、通知或版本发布。文中不记录密码、Token、证书私钥。

## 1. 结论与范围

现有入口是 Windows 批处理和 Android Fastlane，均支持自助买单机与 Kiosk。Windows 集成测试、安装器生成、可选签名和上传通知；Android 集成 APK 构建和上传通知。两者尚不能直接作为可靠的生产打包服务：环境参数存在错配、Android Release 使用 debug 签名、部分失败不会使任务失败、依赖和产物缺少完整追溯。

原生打包不会构建或嵌入当前 Vue 工程的 dist。应用运行时加载远端 Web，因此“原生安装包版本”和“设备实际使用的 Web 版本”必须分别记录。

上传 DUFS 只完成文件分发准备，不等于已登记自动更新版本。现有脚本没有后端版本登记步骤。

### 审计基线

| 项目 | 当前基线 |
| --- | --- |
| Flutter 仓库 | `/Users/dylan/Desktop/candao/self-checkout` |
| 分支 / commit | `qc/octopus-align-toa-fix` / `44b4c804c7dc386702a4d6708140ae0de201e052` |
| 应用版本 | `pubspec.yaml`：`1.4.1+1` |
| Web 仓库 | `/Users/dylan/Desktop/candao/candao-pwa-work-group` |
| 已核对 Web 子项目 | `packages/candao-kiosk` |
| Web commit | `b7b132b7192d109d831e5c6b677719f4010d5756` |
| Octopus 邻仓 commit | `ba094ae8f73837aa38800d1a59c9f43130f3278d` |

上述 commit 是本次源码快照，不代表远端站点已部署这些版本。本文没有审计独立的自助买单机 Web 构建工程。

## 2. 打包入口与产品差异

| 平台 | 入口 | 结果 | 默认外部动作 |
| --- | --- | --- | --- |
| Windows | `scripts/build_windows.bat` | Inno Setup 安装器 `.exe` | 上传 DUFS、钉钉通知；可用 `--local true` 关闭 |
| Android | `android/fastlane/Fastfile` | Release `.apk` | 四个构建 lane 均上传 DUFS、钉钉通知，无仅构建选项 |
| Web Kiosk | Web 仓库 `bootstrap.ts` → 子项目 `vite build` | Web 静态资源 | 本文未确认部署入口 |

`scripts/start_serena_self_checkout.sh` 不是打包入口。仓库未发现受版本控制的 GitHub/GitLab 构建流水线配置，README 仍以 Flutter 模板说明为主。

| 项目 | self_checkout | kiosk |
| --- | --- | --- |
| Dart `product_type` | `self_checkout` | `kiosk` |
| Android flavor | `selfCheckout` | `kiosk` |
| Android applicationId | `com.candao.self_checkout` | `com.candao.kiosk` |
| Android 显示名 | 自助买单机 | Kiosk |
| Windows 显示名 | Self Checkout | Kiosk |
| Windows 主程序 | `self_checkout.exe` | `self_checkout.exe` |
| Windows 安装目录 | `{localappdata}\Programs\SelfCheckout` | `{localappdata}\Programs\Kiosk` |
| Windows 安装器基础名 | `self_checkout_setup` | `kiosk_setup` |
| DUFS Android 目录 | `Self-Checkout-Android` | `Kiosk-Android` |
| DUFS Windows 目录 | `Self-Checkout-Windows` | `Kiosk-Windows` |

Windows 两产品使用不同固定 AppId，但进程名相同；脚本按进程名结束进程可能影响另一产品。Android `namespace=com.example.self_checkout` 不是最终安装包 applicationId。

## 3. 构建模式与环境：必须分开理解

### Windows 参数实际映射

| `--type` | Flutter 模式 | 注入 `app_env` | 文件名环境段 | 实际运行环境 |
| --- | --- | --- | --- | --- |
| debug | debug | debug | debug | development |
| staging | release | staging | staging | staging |
| release / prod | release | prod | release | production |
| test-prod | release | test-prod | test-prod | **development** |

### Android lane 实际映射

| lane | 产品 / flavor | Flutter 模式 | 注入 `app_env` | 实际运行环境 |
| --- | --- | --- | --- | --- |
| build_self_checkout_debug | self_checkout / selfCheckout | release | test-prod | **development** |
| build_self_checkout | self_checkout / selfCheckout | release | prod | production |
| build_kiosk_debug | kiosk / kiosk | release | test-prod | **development** |
| build_kiosk | kiosk / kiosk | release | prod | production |

**原因：** `AppBootstrap` 只识别 `testProd`，脚本传的是 `test-prod`；未知值回退 development。Android lane 名称中的 debug 不代表 Flutter Debug 包。新系统不能直接把 lane 名称当构建模式或环境。

### 实际网络配置

| 运行环境 | 测试功能 | 默认 Kiosk Web | 默认自助买单机 Web | 本地 HTTP 服务端口 |
| --- | --- | --- | --- | --- |
| development | 开启 | QC | QC | 4040 |
| staging | 开启 | QC | QC | 4041 |
| production | 关闭 | 正式 | 正式 | 4042 |
| testProduction（需传 testProd） | 开启 | QC | QC | 4043 |

默认站点：

- Kiosk 正式：`https://kiosk.can-dao.com/#/`；QC：`https://toa-v6-qc-kiosk.can-dao.com/#/`。
- 自助买单机正式：`https://self-checkout.can-dao.com/#/`；QC：`https://toa-v6-qc-self-checkout.can-dao.com/#/`。
- **Flutter `EnvConfig.apiBaseUrl` 所有环境均返回 `http://candao-api-gateway.toa-v6-qc.can-dao.com`。** 正式 Web 不代表 Flutter API 也指向正式环境；Web 自身 API 配置需单独核对。

Kiosk 入口经 `MainPage → ProductConfig.webviewBaseUrl`；自助买单机经 `HomePage → Application.webviewBaseUrl → EnvConfig.webviewBaseUrl`。产品配置的自定义 URL 在启用测试功能时加载；EnvConfig 的持久化 URL 覆盖在启动时加载。设备保留的设置也会改变实际访问地址，验收应读取设备实际 URL。

Windows 传入的 `proxy_type` 在当前 `lib/android/windows` 中未发现消费实现，仅凭 `_proxy` 文件名不能认定应用启用了代理。

## 4. 构建前置条件与依赖锁定

| 范围 | 当前要求 / 状态 | 系统接入要求 |
| --- | --- | --- |
| Flutter / Dart | Dart 约束 `^3.6.1`；`.fvmrc`、`.fvm/` 被忽略，仓库未锁定 Flutter 版本 | 固定 SDK 版本并记录实际版本 |
| Windows | Windows 构建节点、FVM、Flutter Windows 工具链、Visual Studio C++ 工具链、Inno Setup 6、PowerShell、curl | 使用固定构建镜像；脚本强制 `fvm flutter` |
| Windows CMake | 最低 3.14、C++17；脚本固定查找 x64 产物 | 不宣称支持 ARM64 或 Win32 |
| Android | Android SDK、AGP 8.9.1、Gradle 8.11.1、Kotlin 2.1.0 | AGP 8.x 运行使用 JDK 17；记录实际 SDK/NDK |
| Android SDK 参数 | compileSdk/minSdk/targetSdk/ndkVersion 来自 Flutter | 不能从项目文件宣称固定数值 |
| Java 编译目标 | Java/Kotlin 1.8 | 不等于 Gradle 可用 JDK 8 运行 |
| Ruby 工具链 | Gemfile.lock：Fastlane 2.228.0、Bundler 2.7.2；依赖含 abbrev | 固定可兼容 Ruby，按锁文件安装 |
| Gradle 资源 | JVM 最大堆 4G、Metaspace 2G | 节点需预留额外 Flutter/系统内存 |
| Octopus 插件 | path 依赖 `../octopus_payment_flutter` | 按邻仓目录检出并固定 commit；pubspec.lock 不能锁其内容 |
| Octopus 二进制 | Android `android/app/libs/ocrl-release-v7203.aar`；Windows 邻仓 `assets/dll/ocrl.dll`、`lrw.dll` | 校验存在性、来源和 hash |
| KPay | Git ref main；锁文件 resolved-ref `c04eaf8aac46c5f8114a298d7eadb678905b64cf` | 保留锁文件并记录解析后的 commit |
| Web | pnpm 9.15.1、Volta Node 20.17.0 | 独立锁定 Web 源码与共享模块构建 |

Android Flutter 查找顺序是 `which fvm` → 本地 `.fvm/flutter_sdk/bin/flutter` → PATH 的 `flutter`，含 Unix 命令，未验证 Windows Fastlane 可用性。新系统不应允许该回退顺序导致 SDK 静默变化。

## 5. Windows 脚本详细流程

### 参数

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `--product` | self_checkout | self_checkout / kiosk |
| `--type` / `-t` | release | debug / staging / release / prod / test-prod；帮助文本未列全 |
| `--proxy` / `-p` | none | 非 none 时追加 Dart define；无已确认运行效果 |
| `--local` / `-l` | false | **需要 true/false 值**；true 跳过上传通知，不跳过依赖下载 |
| `--output-dir` / `-o` | `build\outputs` | 最终安装包目录 |
| `--iss` | `C:\Program Files (x86)\Inno Setup 6\ISCC.exe` | Inno Setup 编译器 |
| `--skip-analyze` | 不跳过 | 跳过静态分析 |
| `--skip-test` | 不跳过 | 跳过 Flutter 测试 |
| `--help` | — | 显示帮助 |

未知参数进入帮助且退出码为 0；参数缺值没有严格校验。系统接入层应先做白名单及必填校验，不能把退出 0 当作产物存在的证明。

### 执行顺序

1. 切到项目根目录，创建输出、日志和安装器目录。
2. 强制结束运行中的 `self_checkout.exe`。构建节点应专用，不能与业务终端混用。
3. 磁盘检查默认被 `SKIP_DISK_CHECK=1` 跳过；代码中的 2048MB 下限实际未执行。
4. 检查 FVM、Flutter、ISCC。
5. 检测**构建机** WebView2，仅缺少时下载 bootstrapper；下载地址为 Microsoft LinkId=2124703。可选 SHA256 默认空。
6. 下载 VC++ 2015–2022 x64 redistributable（`https://aka.ms/vs/17/release/vc_redist.x64.exe`），打入安装器。
7. 解析 pubspec version，取 `+` 前的版本名，生成 `yyyyMMdd_HHmmss` 时间戳。
8. 依次执行 pub get、analyze、test、build windows；其中分析/测试可被参数跳过。没有自动 clean。
9. 查找 `build/windows/x64/runner/{Debug|Release}/self_checkout.exe`。
10. 缺 libisar.dll 时尝试从根目录补拷贝；复制邻仓 Octopus DLL。DLL 缺失/复制失败可仅警告，不保证阻断打包。
11. 生成 `build/installer/installer_temp.iss`，执行 ISCC，得到中间安装器。
12. 满足签名配置时使用 signtool 签安装器，复制最终产物，删除临时 ISS。
13. 非 local 模式上传 DUFS 并通知钉钉。

虽然创建 `build/logs`，脚本没有完整日志重定向。新系统需捕获 stdout/stderr、退出码、执行阶段和工具版本。

### 安装器行为

- x64compatible、LZMA 压缩，要求管理员权限。
- 打入主程序、DLL、data 和其他构建输出；安装前再次结束 `self_checkout.exe`。
- VC++ 运行库打入安装器，在目标机检测后按需安装。
- **WebView2 是否打入取决于构建机是否已安装。** 构建机已有 WebView2 时，目标机缺少运行库也没有被打入的 bootstrapper 可用。新系统应让安装包内容与构建机状态无关，并明确离线安装需求。
- 普通安装后可启动应用，silent 模式不自动启动。卸载删除 `{app}` 和 `{localappdata}\{MyAppName}`，需评估本地数据保留要求。

### 签名与产物

`SIGNTOOL_PATH`、`SIGN_PFX`、`SIGN_PFX_PWD` 在脚本开头被置空，并不是已经可用的环境变量注入接口。签名配置默认未启用；只签安装器，不能据此宣称内部 exe/DLL 都已签名。当前使用 SHA256 和 DigiCert 时间戳服务。

```text
中间产物：build/installer/{self_checkout_setup|kiosk_setup}_{ENV_NAME}[_proxy].exe
最终产物：build/outputs/{product}_windows_{timestamp}_v{versionName}_{ENV_NAME}_{proxy}.exe
```

文件名不含 buildNumber、commit、证书信息；无 manifest/hash。临时 ISS、HTTP 状态文件及中间安装器使用固定名，复制允许覆盖，不能让多个任务共用同一工作目录。

## 6. Android Fastlane 详细流程

1. 将 `GRADLE_USER_HOME` 设置为项目 `android/.gradle-home`；这是项目隔离，不是任务隔离。
2. 按前述顺序寻找 Flutter，解析版本。
3. 执行 pub get，再执行 `flutter build apk --release --flavor ...`，注入产品与环境。
4. 从固定路径查找 APK，复制到 `build/outputs`。
5. 上传 DUFS，发送钉钉通知。

所有构建 lane 都没有 analyze/test/clean 阶段；没有 AAB、按 ABI 拆包或显式 target-platform 参数。另有 `clean` lane 执行 Flutter clean 和 Gradle clean，`version` lane 打印版本。

版本解析仅接受形如 `1.4.1+1` 的三段数字版本；失败静默回退 `1.0.0+1`，新系统应改为阻断。

```text
脚本查找：build/app/outputs/flutter-apk/app-{flavor}-release.apk
最终产物：build/outputs/{product}_v{versionName}_{app_env}_{timestamp}.apk
```

**产物路径隐患：** Fastlane 拼出 `app-selfCheckout-release.apk`。本机 Flutter 3.41.0 的 `listApkPaths` 将 flavor 转为小写，规则是 `app-selfcheckout-release.apk`。大小写敏感节点可能找不到产物；当前处理为 UI.error + return nil，外层直接返回，可能正常退出但没有发布。此结论来自 SDK 源码静态核对，尚未实际构建验证。

**签名：** `buildTypes.release.signingConfig = signingConfigs.debug`。Release 同时启用 minifyEnabled、shrinkResources 和 ProGuard。正式打包系统必须区分优化模式与签名身份；切换正式证书前先核对已安装设备的证书，否则可能无法覆盖安装。

## 7. Web 工程关系及独立构建

Kiosk 包名为 `@candao/kiosk`，package version 为 `0.0.1`。子项目提供 dev、build、preview、type-check，build 是 `vite build`。

Web 根目录入口：

```text
pnpm build → esno bootstrap.ts --mode=build
           → 选择 kiosk（映射 candao-kiosk）
           → 注入 RUN_ENV
           → 子项目 vite build
```

- `--env/-e` 默认 development，帮助提及 qc/beta，但并没有完整环境白名单。
- 不指定项目会遍历多个项目；打包系统必须明确 kiosk。
- `pnpm compile` 编译共享 `@candao/module-*`；build 入口不自动执行这一步。
- Vite 的 mode 来自 `RUN_ENV || NODE_ENV || production`，结合 `.env` 与所选环境文件。已发现 `.env`、`.env.development`、`.env.production`，不能仅凭任意 env 字符串保证对应配置存在。
- 使用 `@candao/module-build` 共享配置；未发现覆盖 outDir，按 Vite 默认推导为子项目 dist，尚未构建确认。
- PWA 启用 autoUpdate、skipWaiting、clientsClaim；服务工作线程缓存和在线升级会影响终端实际资源版本。
- 根目录 test 是失败占位脚本，不能作为有效测试入口；type-check 可用性及完整 Web 测试仍需独立验证。

新系统至少应关联原生 commit、Web commit、部署环境、部署版本或资源 hash。仅填写 Web commit 不证明远端已经部署，也不能保证旧缓存设备立即切换。Web 部署服务、回滚和桥接兼容策略仍待确认。

## 8. 文件上传、通知与自动更新

### 当前上传

DUFS 是内网 HTTP 文件服务，按上文产品/平台目录存放。脚本含硬编码账户凭证及钉钉 webhook；本文不复制其值。接入系统前应迁移到凭证管理，并评估轮换现有凭证。

- Windows 先 GET 判断目录，200/301 视为存在，否则 MKCOL；随后 curl 上传。
- Android MKCOL 带 `|| true`，随后 curl 上传。
- 两端都缺少可靠的 HTTP 失败判断、远端内容 hash 核验和钉钉业务 errcode 判断。
- Windows 上传/通知失败不会稳定反映为最终非零退出码；Android curl 返回 HTTP 错误时也未必导致 lane 失败。

系统必须分别保存“构建成功”“上传成功”“发布登记成功”“通知成功”，禁止用一条 Build finished 概括全部结果。

### 设备升级链路

```mermaid
flowchart LR
    A[构建与签名] --> B[产物归档]
    B --> C[上传文件]
    C --> D[后端登记发布版本：现有脚本缺失]
    D --> E[设备查询版本]
    E --> F[下载并启动安装]
    F --> G[设备升级结果：需另外确认]
```

设备调用 `actionType=toaSelfBuyMachine`、`actionName=candao.storeDevice.checkVersionUpdate`，请求包含门店、设备、产品和平台：

| 字段 | 当前客户端含义 |
| --- | --- |
| storeId / deviceCode | 当前注册设备信息 |
| publishApp | 字典 sblx 中目标 key，Kiosk 为 sblxkiosk，自助买单机为 sblxzzmdj，并有兜底 |
| publishPlatform | Android 为 3，Win64 为 2；注释中的 Win32=1 不等于支持 Win32 打包 |

客户端消费 `isUpdate`、`lastVersion`、`downloadUrls`、`md5`，使用第一个下载 URL。md5 已解析，但当前下载流程没有据此校验。

版本规范化会去掉 v/V 前缀和 `+buildNumber` 后缀，再比较数字段；当前 DeviceInfoUtil 获取的是 PackageInfo.version。**只递增 buildNumber 不会触发这套应用层版本比较的升级判定。** Android 系统安装的 versionCode 约束仍需独立满足。

Android 下载后打开系统安装界面；Windows 启动安装器且没有 silent 参数。客户端流程完成仅代表已发起安装，不代表设备已成功升级。

后端“登记版本”的写入接口、权限、灰度和审核规则未在现有脚本中提供。上表是客户端查询契约，不能直接作为新建发布的 API 请求体。

## 9. 接入前问题清单

以下优先级是对新系统接入的建议，不代表本次已修复。

| 优先级 | 问题 | 接入要求 |
| --- | --- | --- |
| 阻断正式发布 | Release 使用 Android debug 签名 | 核对存量证书，明确签名策略和可升级路径 |
| 阻断正式发布 | test-prod/testProd 不一致，Flutter API 固定 QC | 产品确认环境矩阵后统一参数；检查实际 endpoint |
| 阻断正式发布 | 凭证/webhook 硬编码 | 秘密引用注入、日志脱敏，评估轮换 |
| 阻断正式发布 | HTTP/业务失败仍可能成功退出 | 明确每阶段成功条件与错误传播 |
| 阻断正式发布 | 上传没有后端发布登记 | 明确接口、发布审批、灰度与回滚流程 |
| 高 | WebView2 内容受构建机状态影响 | 固定安装器依赖策略，在干净目标机验收 |
| 高 | APK flavor 文件名大小写不一致 | 按 SDK 实际输出定位，缺产物强制失败 |
| 高 | Octopus/Isar DLL 缺失仅警告 | 必需文件清单及校验，缺失阻断 |
| 高 | SDK/path 依赖未锁、固定共享目录 | 固定源码与工具版本，单任务工作目录 |
| 高 | 包没有完整 manifest/hash，下载未核验 md5 | 归档 SHA256；按后端兼容性提供 md5，另行补齐客户端校验 |
| 中 | Android 无测试；Windows 可跳过 | 系统显式记录验证结果，正式策略禁止静默跳过 |
| 中 | 版本解析回退、未知参数退出 0 | 严格输入校验，禁止猜测版本 |
| 中 | proxy 参数无运行消费者 | 不作为有效产品能力展示，确认需求后处理 |
| 中 | 构建机 taskkill、磁盘检查默认关闭 | 专用节点、资源预检，避免误杀 |
| 中 | 文件名缺 buildNumber/commit、日志不完整 | 以任务 ID、完整版本和 commit 建立归档索引 |

## 10. 新打包系统的最小接口建议

本节是设计建议，不是已有脚本支持的参数。先完成“可重复构建和归档”，再接上传与版本登记即可；无需先实现复杂调度平台。

### 任务输入

| 输入 | 要求 |
| --- | --- |
| 产品、平台 | 枚举，自动映射 flavor/applicationId，不让用户自由填写冲突组合 |
| 源码版本 | Flutter commit、Octopus commit；涉及 Web 发布时明确 Web commit |
| Flutter 模式 | debug/release，与业务环境独立 |
| 业务环境 | 统一受支持枚举，再转换为 Dart define；同时展示预期 Web/API 地址 |
| 版本 | versionName、buildNumber；无覆盖时明确使用源码 pubspec 值 |
| 工具链配置 | 固定 Flutter、JDK/SDK、Windows 工具、Ruby 或 Node 版本 |
| 签名配置 | 保存 profile ID / 凭证引用，不保存明文口令 |
| 验证策略 | analyze/test 是否必需；正式发布默认必需 |
| 外部动作 | upload、registerRelease、notify 分别开关；构建不隐式发布 |

最小任务示意（占位值需由系统实际解析和校验）：

```json
{
  "product": "kiosk",
  "platform": "android",
  "sourceCommit": "<完整 Flutter commit>",
  "octopusCommit": "<完整 Octopus commit>",
  "buildMode": "release",
  "runtimeEnvironment": "production",
  "versionName": "<目标版本>",
  "buildNumber": "<目标构建号>",
  "toolchainProfile": "<固定工具链配置 ID>",
  "signingProfile": "<签名配置 ID>",
  "upload": false,
  "registerRelease": false,
  "notify": false
}
```

当前脚本未接受版本覆盖参数，也未完成签名 profile 接入。以上配置需要通过后续适配实现，不能直接发送给 Fastlane 或 bat。

### 阶段和结果

建议顺序：`准备源码 → 校验输入和依赖 → analyze/test → build → package → sign → verify → archive → upload → verify_remote → register_release → notify`。Windows package 为 Inno Setup；Android 当前由 Gradle 构建并签名，不能机械拆成第二次重复签名。

- 每个阶段记录 queued/running/succeeded/failed/skipped、起止时间、退出码、脱敏日志及产物引用。
- 单任务独立 checkout、临时目录、输出目录；共享缓存另行管理，不能共用 build 目录。
- 构建失败禁止发布；上传重试复用同一个已校验产物；通知失败可单独重试，不重新构建。
- 上传路径使用不可变任务 ID 或完整版本与 commit，禁止静默覆盖同名不同内容。
- 发布登记用后端支持的幂等方式，接口未确认前不要伪造幂等字段。
- 验证 APK 包名、versionName/versionCode、证书指纹；验证 Windows 安装器签名、必需 DLL、安装与启动。

### 每个任务的归档 manifest

至少记录：任务 ID、请求者、产品/平台、完整源码及依赖 revisions、工作区是否干净、SDK/工具版本、脱敏构建命令、原始与解析后的环境、预期 endpoint、完整应用版本、测试结果、签名指纹、产物名称/大小/SHA256、上传地址、后端发布标识、各阶段状态及日志位置。

Web 部署 revision 与终端实际 Web 版本分别记录，不能混用。签名口令、私钥、上传密码及 webhook Token 不进入 manifest。

## 11. 可复用命令与副作用

下列命令未在本轮执行，需先准备对应平台及依赖。现有生产签名和环境问题未解决前，不应据此发布正式版本。

### Windows：保留验证，只生成本地安装器

在 Flutter 项目根目录的 Windows CMD 执行：

```bat
scripts\build_windows.bat --product kiosk --type release --local true
scripts\build_windows.bat --product self_checkout --type staging --local true
```

`--local true` 仍会下载依赖并结束同名应用进程，只关闭上传与通知。

### Android：仅构建，绕开发布 lane

在 Flutter 项目根目录、固定 FVM SDK 后执行：

```sh
fvm flutter pub get
fvm flutter analyze
fvm flutter test
fvm flutter build apk --release --flavor kiosk --dart-define=product_type=kiosk --dart-define=app_env=prod
```

自助买单机替换为 `--flavor selfCheckout --dart-define=product_type=self_checkout`。这些命令不调用上传/通知，仍使用现有 Gradle debug 签名；prod 的 Flutter API 仍为前述 QC 地址。

现有发布入口示例：在 `android` 目录执行 `bundle exec fastlane android build_kiosk`。**该 lane 会立即上传并发钉钉通知，不是仅构建命令。** 安装 Ruby 依赖需按 Gemfile.lock 使用 bundle install。

### Web Kiosk：独立构建的静态推导命令

在 Web monorepo 根目录执行：

```sh
pnpm install --frozen-lockfile
pnpm compile
pnpm build --env=production kiosk
```

这不是部署命令，尚未执行验证。应核对环境文件和共享模块结果，再接实际站点发布流程。

## 12. 验收与待确认事项

系统接入的最低验收：

- 两产品、两平台可从固定源码在独立目录完成构建；产物版本、产品标识及环境符合任务输入。
- 在大小写敏感 Android 节点验证 APK 定位，缺产物/缺 DLL/测试失败/签名失败均使任务失败。
- 两个任务并发运行不覆盖中间产物；重试上传不改产物 hash。
- Windows 无 WebView2/VC++ 的干净目标机可以安装启动；断网场景符合约定。
- Android 与已有安装包签名兼容，版本可升级；Windows 验证同产品升级与两产品共存。
- 正式包核对实际 Web/API 地址、测试功能开关、设备持久化 URL 和 Web 缓存版本。
- 模拟上传 HTTP 错误、通知业务失败，结果不误报；通知重试不重复发布。
- 后端登记后，指定设备能查询到版本、下载安装；安装后另行核对实际版本和启动状态。
- 日志、manifest、通知均不包含秘密；外部发布和通知按实际审批策略执行。

实施前需业务/运维确认：

1. 正式与测试环境的完整 Web/API 矩阵，testProduction 的真实用途。
2. 正式 Android/Windows 签名身份、存量证书与证书保管方式。
3. 是否要求离线安装，以及 Octopus/Isar 二进制的权威来源。
4. 版本号递增规则；后端发布写入接口、灰度、审批、回滚及设备升级确认方式。
5. Web 部署入口、资源版本标识、缓存刷新策略与原生桥接兼容范围。
6. 构建节点支持的平台、DUFS 可达性、产物保留周期和通知对象。

## 13. 源码索引与本轮验证

以下为本次工作区绝对路径；移到其他机器时按相同仓库相对结构定位。

| 内容 | 源码 |
| --- | --- |
| Windows 参数与完整流程 | [build_windows.bat](/Users/dylan/Desktop/candao/self-checkout/scripts/build_windows.bat:44) |
| Windows 环境映射 | [build_windows.bat](/Users/dylan/Desktop/candao/self-checkout/scripts/build_windows.bat:276) |
| Windows 安装器与签名 | [build_windows.bat](/Users/dylan/Desktop/candao/self-checkout/scripts/build_windows.bat:405) |
| Android 构建与产物定位 | [Fastfile](/Users/dylan/Desktop/candao/self-checkout/android/fastlane/Fastfile:54) |
| Android lanes | [Fastfile](/Users/dylan/Desktop/candao/self-checkout/android/fastlane/Fastfile:131) |
| 产品与签名配置 | [build.gradle](/Users/dylan/Desktop/candao/self-checkout/android/app/build.gradle:34) |
| 环境解析 | [app_bootstrap.dart](/Users/dylan/Desktop/candao/self-checkout/lib/core/application/app_bootstrap.dart:139) |
| API 与 Web 环境 | [env_config.dart](/Users/dylan/Desktop/candao/self-checkout/lib/core/config/env_config.dart:98) |
| 产品及自定义 URL | [product_config.dart](/Users/dylan/Desktop/candao/self-checkout/lib/core/config/product_config.dart) |
| 更新查询与安装 | [system_update_service.dart](/Users/dylan/Desktop/candao/self-checkout/lib/core/service/system_update/system_update_service.dart:60) |
| 更新响应与版本规范化 | [system_update_info.dart](/Users/dylan/Desktop/candao/self-checkout/lib/core/service/system_update/system_update_info.dart:19) |
| Web 构建入口 | [bootstrap.ts](/Users/dylan/Desktop/candao/candao-pwa-work-group/bootstrap.ts:130) |
| Web 模式与 PWA | [vite.config.ts](/Users/dylan/Desktop/candao/candao-pwa-work-group/packages/candao-kiosk/vite.config.ts:9) |
| Web 工具链与命令 | [package.json](/Users/dylan/Desktop/candao/candao-pwa-work-group/package.json:6) |

本轮验证：Fastfile 通过 `ruby -c` 语法检查；文档执行本地链接/行号检查和 `git diff --check`。未修改业务代码或脚本，因此没有重跑 Flutter 单元测试。当前为 macOS 调查环境，未实际验证 Windows 安装器、Android 构建、硬件能力、上传通知或后端发布。
