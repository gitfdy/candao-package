# main 分支多环境构建测试报告

## 结论

- 测试分支：`main`
- 测试时间：2026-10-01 09:18 至 11:16（UTC+8）
- 测试范围：5 个工程、19 个环境组合；Windows 使用 EXE，Android 使用 APK
- 分发设置：上传 DUFS，关闭钉钉通知
- 最终有效结果：**12 项成功，7 项失败，成功率 63.2%**
- 数据审计：19 条结果唯一；12 条成功记录均包含安装包产物和 DUFS 地址

## 工程汇总

| 工程 | 结果 | 结论 |
|---|---:|---|
| TOA POS · Windows | 4/5 成功 | `debug` 的主分支脚本仍错误校验 Release 的 `app.so` |
| 自助收银 · Windows | 0/4 成功 | 主分支脚本不支持流水线传入的 `--product` 参数 |
| 手持 POS · Android | 4/4 成功 | 全部通过 |
| Tappo · Android | 4/4 成功 | 首轮受 GitHub TLS 中断影响，重试后全部通过 |
| Tappo Phone · Android | 0/2 成功 | APK 已生成，但签名证书与流水线期望值不一致 |

## 明细

| 工程 | 环境 | 结果 | 平台 / Jenkins | DUFS 下载 |
|---|---|---|---:|---|
| TOA POS | test-prod | 成功 | #66 / #39 | [下载](http://192.168.225.46:5000/dufs/TOA-POS-Windows/toa-pos_test-prod_07e1e27dac55_39_toa_pos_windows_20261001_v3.9.1_test_prod_no_proxy.exe) |
| TOA POS | pre-prod | 成功 | #73 / #40 | [下载](http://192.168.225.46:5000/dufs/TOA-POS-Windows/toa-pos_pre-prod_07e1e27dac55_40_toa_pos_windows_20261001_v3.9.1_pre_prod_no_proxy.exe) |
| TOA POS | release | 成功 | #76 / #41 | [下载](http://192.168.225.46:5000/dufs/TOA-POS-Windows/toa-pos_release_07e1e27dac55_41_toa_pos_windows_20261001_v3.9.1_release_no_proxy.exe) |
| TOA POS | debug | **失败** | #83 / #42 | — |
| TOA POS | release-debug | 成功 | #84 / #43 | [下载](http://192.168.225.46:5000/dufs/TOA-POS-Windows/toa-pos_release-debug_07e1e27dac55_43_toa_pos_windows_20261001_v3.9.1_release_debug_no_proxy.exe) |
| 自助收银 | staging | **失败** | #67 / #34 | — |
| 自助收银 | test-prod | **失败** | #68 / #35 | — |
| 自助收银 | release | **失败** | #69 / #36 | — |
| 自助收银 | debug | **失败** | #70 / #37 | — |
| 手持 POS | test-prod | 成功 | #71 / #25 | [下载](http://192.168.225.46:5000/dufs/HANDHELP_POS/hpos_test-prod_a30a2cc53def_25.apk) |
| 手持 POS | pre-prod | 成功 | #72 / #26 | [下载](http://192.168.225.46:5000/dufs/HANDHELP_POS/hpos_pre-prod_a30a2cc53def_26.apk) |
| 手持 POS | release | 成功 | #74 / #27 | [下载](http://192.168.225.46:5000/dufs/HANDHELP_POS/hpos_release_a30a2cc53def_27.apk) |
| 手持 POS | debug | 成功 | #75 / #28 | [下载](http://192.168.225.46:5000/dufs/HANDHELP_POS/hpos_debug_a30a2cc53def_28.apk) |
| Tappo | qc | 成功 | #85 / #17 | [下载](http://192.168.225.46:5000/dufs/TAPPO/tappo_android_20261001_103917_v2.4.10_qc_internal.apk) |
| Tappo | beta | 成功 | #91 / #21 | [下载](http://192.168.225.46:5000/dufs/TAPPO/tappo_android_20261001_111430_v2.4.10_beta_internal.apk) |
| Tappo | gray | 成功 | #88 / #19 | [下载](http://192.168.225.46:5000/dufs/TAPPO/tappo_android_20261001_105145_v2.4.10_gray_internal.apk) |
| Tappo | release | 成功 | #90 / #20 | [下载](http://192.168.225.46:5000/dufs/TAPPO/tappo_android_20261001_105849_v2.4.10_release_internal.apk) |
| Tappo Phone | qc | **失败** | #86 / #17 | — |
| Tappo Phone | prod | **失败** | #89 / #18 | — |

## 失败根因

### TOA POS debug

Flutter Debug 可执行文件已成功生成，但 `main` 分支的 `scripts/build_windows.bat` 仍按 Release 流程检查 `build\windows\app.so`，最终报错：

- `ERROR: build\windows\app.so not found - flutter build may have failed`
- `No fresh installer found`

### 自助收银四个环境

`main` 分支的 `scripts/build_windows.bat` 尚未支持 Jenkins 流水线传入的产品参数，四个环境均在编译前报错：

- `Unknown parameter: --product`

### Tappo Phone qc / prod

两个环境都完成了 APK 编译，但签名校验失败：

- `APK signing certificate mismatch`

## 重试说明

Tappo 与 Tappo Phone 首轮受到 Jenkins 节点访问 GitHub 时的 TLS/`early EOF` 中断影响，构建本体未启动。测试对 6 个组合进行了定向重试；Tappo beta 再次遇到 TLS 中断后进行了第二次重试。上表只采用成功进入实际构建流程后的最终有效结果。

## Kiosk 后续处理：分支支持校验（2026-10-01）

用户确认保留应用仓库 main 现状，在打包平台明确提示不支持 Kiosk；不将失败任务改记为打包成功。

- Jenkins #37 实际检出 self-checkout `main@fa4a4b473cfb9a072159751debff56ca7059cccf`，在编译前报 `Unknown parameter: --product`。
- 该源码不含 `lib/core/config/product_config.dart`，WebView 默认入口为 Self Checkout。不能通过删除产品参数来冒充 Kiosk 构建。
- 平台根据所选分支的 Windows 参数解析、`product_type` 编译参数与产品配置检查支持情况，不按分支名称硬编码。
- 页面在不支持时显示原因并禁用下一步；后端提交时再次校验，在创建构建记录和调用 Jenkins 前拒绝请求。GitLab 读取异常时阻止提交。
- 已用本次拉取的真实源码验证：main 的四个环境均返回 400，Jenkins 调用为 0；`devlop_qc@e5a0ff6cf927b2e81eff128e3e882afa165011c7` 通过支持检查。
- 本地浏览器验证：main 显示不支持提示且下一步禁用；切换 devlop_qc 后恢复可操作。
- 25 项自动测试和网页构建通过。未修改应用 main，未触发新构建、上传或通知；线上平台需部署此版本后生效。

## Tappo Phone 后续处理：签名与版本兼容（2026-10-01）

- Jenkins #17、#18 检出的应用为 `main@726c8724d7bbdff12d855fc2104f35c62b1a7589`。该分支的 release 构建固定使用 Flutter 默认 debug 签名，忽略 Jenkins 密钥，因而在 APK 编译完成后报 `APK signing certificate mismatch`。
- 流水线提交 `d25cb73` 只在 Jenkins 临时检出目录适配已识别的旧签名模板，使用 Jenkins 提供的密钥；构建后恢复原文件。已有环境变量签名配置保持不变，未知配置拒绝覆盖，APK/AAB 证书校验继续保留。
- #19、#20 在读取流水线前因 Windows 本机代理未启动失败；代理恢复后 #21 已通过 APK 签名校验，随后暴露 `Cannot read application version`：main 的应用 pubspec 未声明版本。#22 则在读取流水线时遇到 GitHub `Empty reply from server`，未执行编译。
- #23、#24 验证发现，未声明版本时 Flutter 的 `android/local.properties` 同样不含版本字段，`26a41ba` 的回退不足以解决问题。最终改为使用 Android SDK 的 `aapt dump badging` 读取 APK 实际版本，包含 Gradle 的默认值或覆盖值；AAB 保留声明版本校验。
- 本地检查通过：环境/格式组合、版本号参数、AAB 密钥要求、密码转义、真实临时证书指纹及错误密码拒绝、旧签名模板适配、现有签名配置保留、未知配置拒绝、AAB 声明版本/APK 实际版本读取及非法版本拒绝。

最终通过平台重新提交，分支均为 `main`，流水线版本为 `8415a6a`，上传与钉钉通知均关闭：

| 环境 | 平台 / Jenkins | 结果 | Jenkins 归档产物 |
|---|---|---|---|
| qc | #98 / [#25](http://package.sa1.tunnelfrp.com/job/TAPPO-PHONE-Android/25/) | SUCCESS | `tappo_phone_android_20261001_184931_v1.0_qc_internal.apk` |
| prod | #99 / [#26](http://package.sa1.tunnelfrp.com/job/TAPPO-PHONE-Android/26/) | SUCCESS | `tappo_phone_android_20261001_185454_v1.0_prod_internal.apk` |

两个任务均通过 APK 签名校验和产物归档，平台也返回 SUCCESS。两份 `signing-certificate.txt` 指纹一致：`8C8CE0AECA51625F5B80E36344699D44FBEED60C6B620D45E3E6CDAAB9A3F1F8`。

另下载 #25 的 APK（46,873,249 字节）独立复核：`apksigner verify` 通过，证书与归档记录一致；`aapt` 读到包名 `com.tappotechnologylimited.mobile`、versionName `1.0`、versionCode `1`。文件 SHA-256 为 `3F4850CB2F742459F2BDB2D516E7006CCCD2AB3719280E775E762E02EA54D99B`，与 Jenkins 构建日志一致。公网代理传输中出现截断和 503，分段重取后完整性校验通过。

本次验证的是内部签名 APK 构建；未验证 Google Play 密钥/AAB、设备安装或业务功能。开头矩阵保留首轮历史结果，上述两项为修复后的复测结果。
