# 打包系统对接说明

本文描述仓库内现有打包脚本。新打包系统应优先接入“原生 C# 双角色流水线”。Flutter 流水线是旧实现，不能与原生流水线混用。

## 1. 流水线选择

| 流水线 | 主入口 | 产物 | 状态 |
| --- | --- | --- | --- |
| 原生 C# 双角色 | `scripts/build.ps1` | `queue_screen_caller[_qc].exe`、`queue_screen_other[_qc].exe` | 当前 Windows 发布入口 |
| Flutter Windows | `scripts/build_windows.bat` | `queue_screen_windows_<时间>_v<版本>_<环境>.exe` | 旧流水线，仅兼容保留 |

原生流水线使用 `src_csharp/CandaoQueueScreen.sln`。Flutter 流水线使用根目录 `pubspec.yaml` 和 `windows/`。两者使用不同可执行文件、依赖、安装脚本和输出命名。

## 2. 原生 C# 双角色流水线

### 2.1 入口与输入

交互入口：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build.ps1
```

系统集成入口：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\core\build-package.ps1 -Env qc
```

`Env` 仅允许：

| 值 | 含义 | 安装包文件名 |
| --- | --- | --- |
| `qc` | 测试环境 | `queue_screen_caller_qc.exe`、`queue_screen_other_qc.exe` |
| `release` | 正式环境 | `queue_screen_caller.exe`、`queue_screen_other.exe` |

`build.ps1` 还提供分发模式：

| 模式 | 行为 |
| --- | --- |
| `none` | 仅本地打包 |
| `dufs` | 打包后上传 DUFS |
| `full` | 上传 DUFS、OSS，并发送钉钉通知 |

新系统应把环境和分发模式作为两个独立字段。不要依赖交互菜单序号。

### 2.2 执行流程

1. 将 `src_csharp/CandaoQueueScreen/App.config` 的 `ENV` 改为请求环境。
2. 定位 MSBuild；找不到时失败。
3. 定位或下载 `nuget.exe` 到 `build/tools/nuget.exe`。
4. 运行 `nuget restore src_csharp/CandaoQueueScreen.sln`。
5. 运行 MSBuild：`Release`、`Any CPU`。
6. 检查 `src_csharp/CandaoQueueScreen/bin/Release/CandaoQueueScreen.exe`。
7. 缓存不存在时下载 WebView2 与 .NET Framework 4.8 安装器至 `build/installer/`。
8. 用 Inno Setup 分别编译 `caller` 和 `other` 两个安装包。
9. 将原始安装包重命名至 `build/outputs/` 的稳定文件名。
10. 如选择分发，依次执行 DUFS、OSS、钉钉通知。

构建脚本会修改工作区的 `App.config`。新系统必须使用临时 checkout 或在任务结束后还原该文件，避免并发任务和源代码污染。

### 2.3 Caller 与 Other

不是两个项目。两包使用同一份 `CandaoQueueScreen.exe`：

| 角色 | 安装器编译参数 | 启动参数 | 安装目录 |
| --- | --- | --- | --- |
| Caller | `/DInstallerRole=caller` | 无 | `%LOCALAPPDATA%\Programs\CandaoQueueScreen` |
| Other | `/DInstallerRole=other` | `--role other` | `%LOCALAPPDATA%\Programs\CandaoQueueScreenOther` |

两角色 AppId 不同，可安装在同一台机器。安装器会分别建立防火墙规则。

### 2.4 工具与缓存

| 项目 | 检查或默认位置 | 缺失行为 |
| --- | --- | --- |
| MSBuild | VS2022 / Build Tools，或 `vswhere` | 失败 |
| NuGet | PATH；否则 `build/tools/nuget.exe` | 自动下载 |
| Inno Setup 6 | `C:\Program Files (x86)\Inno Setup 6\ISCC.exe` | 失败 |
| WebView2 bootstrapper | `build/installer/MicrosoftEdgeWebview2Setup.exe` | 自动下载 |
| .NET Framework 4.8 bootstrapper | `build/installer/ndp48-web.exe` | 自动下载 |

系统应预装 MSBuild 与 Inno Setup。NuGet 和运行时安装器建议放在构建缓存，不要在每次任务中下载。

### 2.5 成功判断与输出

构建成功条件：

- `build-package.ps1` 退出码为 `0`。
- `build/outputs/` 存在与环境匹配的 Caller、Other 安装包。
- 两文件名符合第 2.1 节命名规则。

脚本会覆盖同环境的旧稳定文件名。新系统如需保留历史，应在任务完成后复制或上传产物，以构建 ID、Git SHA 或时间戳归档。

### 2.6 分发配置

本地私密配置文件：

```powershell
copy scripts\core\config.ps1.example scripts\core\config.ps1
```

`config.ps1` 已被忽略，不应提交。OSS 环境变量优先于该文件：

```text
OSS_ENDPOINT
OSS_BUCKET
OSS_ACCESS_KEY
OSS_ACCESS_SECRET
OSS_PREFIX
```

OSS 对象路径：

```text
{OSS_PREFIX}/{Env}/{安装包文件名}
```

DUFS、钉钉可由 `config.ps1` 覆盖。当前脚本仍含默认 DUFS 账号和钉钉 webhook；新系统不得复用硬编码凭据，应改为密钥管理服务或 CI Secret 注入。

### 2.7 分发失败语义

| 阶段 | 失败是否使打包失败 |
| --- | --- |
| NuGet、MSBuild、Inno Setup、产物检查 | 是 |
| DUFS 上传 | 否，返回空下载地址 |
| OSS 未配置或上传失败 | 否，返回空下载地址 |
| 钉钉通知失败 | 否，仅输出警告 |

新系统应将“构建成功”和“分发成功”分开显示。若发布必须要求所有渠道成功，应由系统层增加发布门禁，不能依赖当前脚本退出码。

## 3. 旧 Flutter Windows 流水线

入口：

```bat
scripts\build_windows.bat --type qc --local true
```

环境：`qc`、`release`、`debug`。流程为 `fvm flutter pub get`、可选 analyze、可选 test、`fvm flutter build windows`、动态生成 Inno Setup 脚本、打包、可选 DUFS 与钉钉通知。

关键输入：

| 参数 | 作用 |
| --- | --- |
| `--type` / `-t` | `qc`、`release`、`debug` |
| `--local` / `-l true` | 不上传、不通知 |
| `--output-dir` / `-o` | 最终目录 |
| `--iss` | ISCC 路径 |
| `--skip-analyze` | 跳过静态检查 |
| `--skip-test` | 跳过测试 |

此流水线从 `pubspec.yaml` 取版本，输出带时间戳：

```text
build/outputs/queue_screen_windows_<时间戳>_v<版本>_<环境>.exe
```

除维护旧 Flutter 发布外，新系统不应选择该流水线。它与原生流水线不共享环境配置、运行时和产物命名。

## 4. 推荐系统任务模型

最小任务字段：

```json
{
  "pipeline": "native-csharp",
  "environment": "qc",
  "distribution": "none",
  "gitRef": "qc/v1.0.1_win"
}
```

执行时记录：Git SHA、开始/结束时间、工具版本、标准输出、Caller 产物路径、Other 产物路径、各渠道下载 URL、各阶段状态。

当前脚本没有单独构建 Other 的官方参数。系统请求 Other 包时，仍运行原生流水线一次，并从两个产物中取 `queue_screen_other[_qc].exe`。

## 5. 已知文档与脚本偏差

- `src_csharp/README.md` 提到的 `scripts/build_csharp.bat` 不存在；实际入口是 `scripts/build.ps1` 和 `scripts/core/build-package.ps1`。
- `build-package.ps1` 文件头的 `pick_up_*` 示例已过期；实际输出是 `queue_screen_*`。
- 根 `README.md` 与 `docs/Windows打包手册.md` 描述的是旧 Flutter 流水线。

新系统以脚本实际行为为准。
