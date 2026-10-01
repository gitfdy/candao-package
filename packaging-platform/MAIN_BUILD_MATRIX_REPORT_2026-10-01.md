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
