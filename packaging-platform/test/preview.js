// Default fixture uses fake services; --live-branches reads GitLab only.
import { resolve } from 'node:path';
import { readFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { createApp } from '../server/app.js';
import { openStore } from '../server/store.js';
import { hashPassword } from '../server/auth.js';
import { remoteClients } from '../server/remotes.js';
import { fail } from '../server/projects.js';
const root = fileURLToPath(new URL('../', import.meta.url));
const live = process.argv.includes('--live-branches');
const local = live ? JSON.parse(readFileSync(resolve(root, 'config.local.json'), 'utf8')) : null;
if (live && !local.gitlab?.token) throw new Error('请先在 config.local.json 填写 gitlab.token（read_api 权限）');
if (live) mkdirSync(resolve(root, 'data'), { recursive: true });
const store = openStore(live ? resolve(root, 'data/branch-preview.sqlite') : ':memory:');
const unavailable = async () => fail('真实分支预览暂不支持 Jenkins 构建，请配置正式服务后使用。', 503);
let requests = 0;
const app = await createApp({
  config: {
    previewBranchesOnly: live,
    publicOrigin: 'http://localhost:3101', secureCookies: false,
    jenkins: live ? local.jenkins : { token: 'fake-jenkins', jobs: {} }, gitlab: live ? local.gitlab : { token: 'fake-gitlab' },
    signingKeys: live ? local.signingKeys : { 'tappo-phone': [{ id: 'demo-key', label: '测试上传凭据' }] },
    users: [{ username: 'preview', role: 'admin', passwordHash: hashPassword('local-preview-only') }]
  },
  store, staticRoot: resolve(root, 'dist'),
  remotes: live ? {
    branches: remoteClients(local).branches,
    trigger: unavailable, queue: unavailable, build: unavailable, log: unavailable, artifact: unavailable
  } : {
    branches: async () => ['devlop_qc', 'feature/example'],
    trigger: async () => ++requests,
    queue: async () => ({ executable: { number: 1 } }),
    build: async () => ({ building: false, result: 'SUCCESS', artifacts: [{ fileName: 'example.txt', relativePath: 'example.txt' }] }),
    log: async () => ({ text: 'Local test finished. No remote services called.', next: 0, more: false }),
    artifact: async () => new Response('Local acceptance fixture')
  }
});
await app.listen({ host: '127.0.0.1', port: 3101 });
console.log(`${live ? '真实 GitLab 分支预览' : 'Local fixture'}: http://localhost:3101 / preview / local-preview-only`);
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, async () => { await app.close(); store.close(); process.exit(0); });
