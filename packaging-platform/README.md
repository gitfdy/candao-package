# Mobile Build

独立目录，不修改现有 Jenkinsfile 或开发源码目录。Vue 3 前端、Fastify 服务端、Node.js 内置 SQLite；Node 同时提供页面和 API，不需要单独部署前端服务。

## 已实现

- 默认访客模式（`allowGuestBuilds: true`）：无需登录即可查看分支、打包、查看构建日志和下载安装包；提交人统一记录为“访客”。分支说明和变更备注仅管理员登录后可修改。关闭此选项后，所有 API 需登录，`builder` 可打包和查看构建。所有账号和访客均可访问已配置的所有项目，暂不提供按项目隔离。
- GitLab 实时分支列表、需求名称及测试说明、编辑冲突检测、操作审计。
- 项目固定白名单、环境和分支独立选择、按原 Pipeline 映射参数。
- Tappo / Phone 支持 APK 和 AAB；HPOS 原流水线仅支持 APK，Windows 为 EXE。
- DUFS、钉钉默认关闭。TOA 支持原有 Incident 开关；Kiosk 支持产品选择；Tappo 支持版本号和已有签名凭据。
- 确认后触发真实 Jenkins，保存请求快照、提交人、队列和构建编号；重复请求不会重复触发。
- 平台提交记录、状态、分段日志、安装包下载（访客模式公开可访问，关闭后需登录）。暂不导入 Jenkins 原有历史构建。

知识库、应用商店发布、自动创建 Jenkins 任务、线上凭据上传不在首版范围。

## Windows 首次部署

1. 安装 **Node.js 24 LTS**。建议目录 `D:\services\candao-package\packaging-platform`，不要放在 Jenkins 会清理的 workspace 下。
2. 在此目录执行：

```powershell
npm ci
npm run build
Copy-Item config.example.json config.local.json
```

3. 编辑 `config.local.json`：
   - `jenkins.url`：同机通常为 `http://127.0.0.1:8080`，允许包含 Jenkins context path。
   - `jenkins.username` / `token`：服务账号及 **API Token**，不是登录密码。需对应任务的 Read、Build、读取产物权限。Token 调用不需要关闭 Jenkins CSRF。
   - `gitlab.url` / `token`：GitLab 根地址及可读取这些仓库分支的 Token（`read_api`）。不能复用只允许 Git 拉代码、无 API 访问权限的 Token。
   - `publicOrigin`：同事实际打开的地址，如 `https://package.example.com`，没有末尾斜线。必须与浏览器 Origin 一致。
   - `allowedOrigins`：可选的额外受信任访问地址数组，例如 `["http://localhost:3100"]`，只允许确切地址，不支持通配符。
   - `host`：穿透客户端和平台同机时保持 `127.0.0.1`；局域网直连才改 `0.0.0.0`。`port` 默认 3100。
   - HTTPS 入口设 `secureCookies: true`。仅本机调试 HTTP 时保持 false。对外使用 HTTPS 穿透/反向代理，不使用明文 HTTP 传账号和会话。
   - `jenkins.jobs`：部署时核对任务真实名称；默认是 TOA-POS-Windows、TOA-KIOSK-WINDOWS、TOA-HPOS-Android、TAPPO-Android、TAPPO-PHONE-Android。若改名，例如配置 `"hpos": "HPOS-Android-Package"`。支持文件夹路径 `folder/job-name`。
   - `signingKeys`：按项目配置可选凭据名称，例如：

```json
"signingKeys": {
  "tappo": [],
  "tappo-phone": [{ "id": "phone-upload-key", "label": "Google Play 原上传密钥" }]
}
```

这里仅保存凭据 ID；JKS 和密码仍在 Jenkins。按现有 Pipeline 同时配置 `<id>-passwords`（别名/库密码）、`<id>-key-password`、`<id>-sha256`。Tappo Phone AAB 强制选择密钥。已有 Pipeline 会验证签名指纹。不要将密码、JKS、Token 放入页面或 Git。

4. 创建平台账号：

填写 Jenkins 配置后，可先执行 `npm run check:jenkins`，验证服务账号认证、任务读取和平台所需参数。检查不会触发构建；Jenkins 服务账号仍需对应任务的 Build 和读取产物权限。

```powershell
npm run user
```

输入用户名、角色 `admin` 或 `builder` 和至少 12 位密码；密码不回显，只保存 scrypt 哈希。每位同事创建自己的账号。新增账号后重启平台。

忘记密码时可重置已有账号，仍只保存新的 scrypt 哈希：

```powershell
npm run user -- --reset admin
```

5. 启动：

```powershell
powershell -NoProfile -File scripts/start.ps1
```

浏览器打开 `publicOrigin`。Jenkins 8080 和平台 3100 是两个独立服务。穿透对外指向 **3100**，不要覆盖现有 Jenkins 入口。

## 自动启动与更新

先前台启动确认成功，再在 Windows「任务计划程序」创建任务：

- 使用专门的本地服务账号，授予平台目录读取及 `data` 目录写入权限。
- 触发器：系统启动时；允许未登录运行。
- 程序：`node.exe` 的绝对路径。
- 参数：`server/index.js`；起始目录：平台目录。
- 设置失败后重新启动；取消默认运行时长限制。

本仓库不自动安装系统服务，不修改防火墙、Jenkins 或系统代理。

更新前停止平台，备份整个 `data` 目录及 `config.local.json`，再更新代码、`npm ci`、`npm run build`、重新启动。不要覆盖本地配置或删除 SQLite 文件。限制配置文件和备份的 NTFS 访问权限；只允许服务账号及管理员读取。配置、数据库、依赖和构建目录均已加入本目录 `.gitignore`。

## 验证与运维

```powershell
npm test
npm run build
```

自动测试使用内存 SQLite 和假远端服务，不会触发 Jenkins、上传或发通知。部署后先验证登录、分支读取、说明保存；真实构建需要在确认页明确提交。首次选择不上传、不通知，检查源码提交、环境与产物，再按需要开启分发。

- `SUBMITTING`：正在提交。进程在此时退出，重启后标记 `UNKNOWN`。
- `UNKNOWN`：Jenkins 可能已接收请求，禁止盲目重提。由管理员到 Jenkins 核对。
- 暂时无法同步：保留最后状态，不冒充失败或成功。队列记录已被 Jenkins 清除且平台尚未获取构建编号时，也需要在 Jenkins 核对。
- 状态每 10 秒后台同步；浏览器每 5 秒读取。通知结果以原流水线规则为准。
- 日志可能包含业务信息，访客模式下访问平台的人均可查看；关闭访客模式后仅平台账号可访问。Jenkins 必须继续使用其凭据掩码。服务端额外遮盖平台持有的两个 Token，不保证识别任意业务密钥。
- 会话保留 8 小时，重启后重新登录；同机单实例运行，不支持多进程横向部署。
- 审计保存在 SQLite `audit` 表；构建请求快照保存在 `builds` 表。请定期备份并按团队保留规则清理，首版不自动删除数据。

## 本地开发

### 仅接入真实分支数据

在 `config.local.json` 配置 `gitlab.url` 和具有 `read_api` 权限的 `gitlab.token` 后，使用 Node.js 24 运行 `npm run preview:branches`。
打开 `http://localhost:3101`，账号 `preview`，密码 `local-preview-only`。此模式仅绑定本机，分支来自真实 GitLab，分支说明保存在 `data/branch-preview.sqlite`，重启后保留。Jenkins 操作禁用，不需要 Jenkins Token。此账号仅用于本地预览；正式部署仍应创建个人账号并运行 `npm start`。原 `node test/preview.js` 保持使用模拟数据。

配置同上，服务端运行 `npm start`；另开终端 `npm run dev`。开发时 `publicOrigin` 改成 Vite 实际地址（通常 `http://localhost:5173`）。Vite 将 `/api` 转发到 3100。生产只需 `npm run build` 后运行 Node。

### 个人备忘录

左侧“个人备忘录”用于保存跨项目的命令和操作说明，支持搜索、复制、编辑和删除。需要登录，每个账号只能访问自己的内容；多人使用同一个账号会共享该账号的备忘录。访客不可访问。

内容保存在平台现有 SQLite 数据库中，升级后首次启动自动创建表，无需额外配置。备份平台数据库时会一并备份备忘录。该功能不提供加密保险箱能力，请勿用于保存密码或令牌。
