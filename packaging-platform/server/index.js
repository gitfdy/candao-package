import { readFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { openStore } from './store.js';
import { createApp } from './app.js';
import { remoteClients } from './remotes.js';

const root = fileURLToPath(new URL('../', import.meta.url));
const config = JSON.parse(readFileSync(resolve(root, 'config.local.json'), 'utf8'));
if (!config.users?.length || config.users.some(user => !['admin', 'builder'].includes(user.role) || !/^[a-f0-9]{32}:[a-f0-9]{128}$/.test(user.passwordHash))) throw new Error('请先执行 npm run user 创建本地账号');
if (new Set(config.users.map(user => user.username)).size !== config.users.length) throw new Error('账号名重复');
const origin = new URL(config.publicOrigin);
if (origin.origin !== config.publicOrigin) throw new Error('publicOrigin 必须为访问页面的协议和域名，不包含路径或末尾斜线');
if (origin.protocol === 'https:' && !config.secureCookies) throw new Error('HTTPS 入口必须开启 secureCookies');
if (!config.jenkins.token || !config.gitlab.token) throw new Error('请配置 Jenkins API Token 和 GitLab Token');
for (const endpoint of [config.jenkins.url, config.gitlab.url]) {
  const url = new URL(endpoint);
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash) throw new Error('无效服务地址');
}
mkdirSync(resolve(root, 'data'), { recursive: true });
const store = openStore(resolve(root, 'data/platform.sqlite'));
store.db.prepare("UPDATE builds SET status='UNKNOWN',error='服务重启前的提交结果未确认，请在 Jenkins 核对。' WHERE status='SUBMITTING'").run();
const app = await createApp({ config, store, remotes: remoteClients(config), staticRoot: resolve(root, 'dist') });
await app.listen({ host: config.host || '127.0.0.1', port: config.port || 3100 });
console.log(`打包平台已启动：${config.publicOrigin}`);
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, async () => { await app.close(); store.close(); process.exit(0); });
