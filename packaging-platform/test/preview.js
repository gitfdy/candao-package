// Local UI acceptance fixture. Never imports credentials or connects to real services.
import { resolve } from 'node:path';
import { createApp } from '../server/app.js';
import { openStore } from '../server/store.js';
import { hashPassword } from '../server/auth.js';
const store = openStore(':memory:');
let requests = 0;
const app = await createApp({
  config: {
    publicOrigin: 'http://localhost:3101', secureCookies: false,
    jenkins: { token: 'fake-jenkins', jobs: {} }, gitlab: { token: 'fake-gitlab' },
    signingKeys: { 'tappo-phone': [{ id: 'demo-key', label: '测试上传凭据' }] },
    users: [{ username: 'preview', role: 'admin', passwordHash: hashPassword('local-preview-only') }]
  },
  store, staticRoot: resolve('dist'),
  remotes: {
    branches: async () => ['devlop_qc', 'feature/example'],
    trigger: async () => ++requests,
    queue: async () => ({ executable: { number: 1 } }),
    build: async () => ({ building: false, result: 'SUCCESS', artifacts: [{ fileName: 'example.txt', relativePath: 'example.txt' }] }),
    log: async () => ({ text: 'Local test finished. No remote services called.', next: 0, more: false }),
    artifact: async () => new Response('Local acceptance fixture')
  }
});
await app.listen({ host: '127.0.0.1', port: 3101 });
console.log('Local fixture: http://localhost:3101 / preview / local-preview-only');
