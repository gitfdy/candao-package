import test from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../server/app.js';
import { openStore } from '../server/store.js';
import { hashPassword } from '../server/auth.js';
import { buildParameters, projects } from '../server/projects.js';
import { remoteClients } from '../server/remotes.js';

const origin = 'http://localhost:3100';
const config = {
  publicOrigin: origin, secureCookies: false,
  jenkins: { url: 'http://jenkins.test', username: 'service', token: 'jenkins-secret', jobs: {} },
  gitlab: { url: 'https://gitlab.test', token: 'gitlab-secret' },
  signingKeys: { 'tappo-phone': [{ id: 'phone-key', label: 'Phone' }] },
  users: [
    { username: 'admin', role: 'admin', passwordHash: hashPassword('correct-password-123') },
    { username: 'tester', role: 'builder', passwordHash: hashPassword('correct-password-123') }
  ]
};
async function fixture(t, overrides = {}) {
  const store = openStore(':memory:'); let count = 0, sent;
  const remotes = {
    branches: async () => ['qc', 'feature/example'],
    trigger: async (job, parameters) => { count++; sent = { job, parameters }; return 7; },
    queue: async () => ({ executable: { number: 12 } }),
    build: async () => ({ building: false, result: 'SUCCESS', artifacts: [{ fileName: 'installer.exe', relativePath: 'artifacts/installer.exe' }] }),
    jenkinsActivity: async () => ({ queue: [], capacity: 2, running: 0 }),
    log: async () => ({ text: 'jenkins-secret gitlab-secret finished', next: 44, more: false }),
    artifact: async () => new Response('artifact-bytes')
  };
  const app = await createApp({ config: { ...config, ...overrides }, store, remotes });
  t.after(async () => { await app.close(); store.close(); });
  async function login(username = 'admin') {
    const result = await app.inject({ method: 'POST', url: '/api/login', headers: { origin, 'x-platform-request': '1' }, payload: { username, password: 'correct-password-123' } });
    assert.equal(result.statusCode, 200);
    return result.headers['set-cookie'].split(';')[0];
  }
  const cookie = await login();
  const send = (method, url, payload, session = cookie, extraHeaders = {}) => app.inject({ method, url, payload, headers: { cookie: session, origin, 'x-platform-request': '1', ...extraHeaders } });
  return { app, store, remotes, login, send, count: () => count, sent: () => sent };
}
const build = { project: 'toa-pos', branch: 'qc', environment: 'pre-prod', format: 'exe', upload: false, notify: false, requestId: 'request-1234567890' };

test('guest builds allow browsing and submission while notes remain admin-only', async t => {
  const f = await fixture(t, { allowGuestBuilds: true });
  assert.equal((await f.app.inject('/api/me')).json().role, 'guest');
  assert.equal((await f.app.inject('/api/projects')).statusCode, 200);
  assert.equal((await f.app.inject('/api/projects/toa-pos/branches')).statusCode, 200);
  assert.equal((await f.send('PUT', '/api/projects/toa-pos/notes', { branch: 'qc', name: 'changed', description: '' }, '')).statusCode, 403);
  assert.equal((await f.send('PUT', '/api/projects/toa-pos/notes', { branch: 'qc', name: 'changed', description: '' })).statusCode, 200);
  const result = (await f.send('POST', '/api/builds', build, '')).json();
  assert.equal(result.status, 'QUEUED');
  assert.equal(result.actor, '访客');
  await f.send('POST', '/api/builds', build, '');
  assert.equal(f.count(), 1);
  assert.equal((await f.app.inject({ method: 'POST', url: '/api/builds', payload: { ...build, requestId: 'other-request-123456' } })).statusCode, 403);
  assert.equal((await f.send('GET', `/api/builds/${result.id}`, undefined, '')).statusCode, 200);
  assert.equal((await f.send('GET', `/api/builds/${result.id}/artifacts/0`, undefined, '')).statusCode, 200);
  await f.send('POST', '/api/logout');
  assert.equal((await f.send('PUT', '/api/projects/toa-pos/notes', { branch: 'qc', name: 'changed', description: '' })).statusCode, 403);
});

test('explicit external origins are accepted while unrelated origins remain blocked', async t => {
  const f = await fixture(t, { allowGuestBuilds: true, allowedOrigins: ['http://package.sa1.tunnelfrp.com'] });
  const call = origin => f.app.inject({ method: 'POST', url: '/api/logout', headers: { origin, 'x-platform-request': '1' } });
  assert.equal((await call('http://package.sa1.tunnelfrp.com')).statusCode, 200);
  assert.equal((await call('http://other.example')).statusCode, 403);
  assert.equal((await call('http://package.sa1.tunnelfrp.com.evil.example')).statusCode, 403);
  assert.equal(f.count(), 0);
});

test('live branch preview rejects builds before reserving or dispatching', async t => {
  const store = openStore(':memory:');
  const app = await createApp({ config: { ...config, previewBranchesOnly: true }, store, remotes: {
    branches: async () => { throw new Error('must not read branches'); },
    trigger: async () => { throw new Error('must not trigger Jenkins'); }
  } });
  t.after(async () => { await app.close(); store.close(); });
  const login = await app.inject({ method: 'POST', url: '/api/login', headers: { origin, 'x-platform-request': '1' }, payload: { username: 'admin', password: 'correct-password-123' } });
  const response = await app.inject({ method: 'POST', url: '/api/builds', headers: { origin, 'x-platform-request': '1', cookie: login.headers['set-cookie'].split(';')[0] }, payload: build });
  assert.equal(response.statusCode, 403);
  assert.equal(store.db.prepare('SELECT count(*) AS count FROM builds').get().count, 0);
});

test('login, origin checks, roles and server-side project allowlist', async t => {
  const f = await fixture(t);
  assert.equal((await f.app.inject('/api/projects')).statusCode, 401);
  assert.equal((await f.app.inject({ method: 'POST', url: '/api/login', payload: {} })).statusCode, 403);
  const tester = await f.login('tester');
  assert.equal((await f.send('PUT', '/api/projects/toa-pos/notes', { branch: 'qc', name: 'Test', description: '' }, tester)).statusCode, 403);
  assert.equal((await f.send('POST', '/api/builds', { ...build, project: 'arbitrary-job' })).statusCode, 404);
  assert.equal(f.count(), 0);
});
test('notes persist, conflict detection, build parameter mapping and idempotency', async t => {
  const f = await fixture(t);
  assert.equal((await f.send('PUT', '/api/projects/toa-pos/notes', { branch: 'qc', name: '验收', description: '范围' })).statusCode, 200);
  assert.equal((await f.send('PUT', '/api/projects/toa-pos/notes', { branch: 'qc', name: '冲突', description: '' })).statusCode, 409);
  const branches = (await f.send('GET', '/api/projects/toa-pos/branches')).json();
  assert.equal(branches[0].name, '验收');
  const response = await f.send('POST', '/api/builds', build);
  assert.equal(response.statusCode, 201);
  const id = response.json().id;
  assert.equal((await f.send('POST', '/api/builds', build)).json().id, id);
  assert.equal(f.count(), 1);
  assert.equal(f.sent().parameters.ENVIRONMENT, 'pre-prod');
  assert.equal(f.sent().parameters.SEND_DINGTALK, 'false');
  const detail = (await f.send('GET', `/api/builds/${id}`)).json();
  assert.equal(detail.status, 'SUCCESS'); assert.equal(detail.number, 12);
  assert.equal(detail.publicOrigin, origin);
  const log = (await f.send('GET', `/api/builds/${id}/log`)).json();
  assert.equal(log.text, '**** **** finished');
  const artifact = await f.send('GET', `/api/builds/${id}/artifacts/0`);
  assert.equal(artifact.body, 'artifact-bytes');
  assert.match(artifact.headers['content-disposition'], /attachment/);
  f.remotes.artifact = async (job, number, path, range) => {
    assert.equal(range, 'bytes=0-3');
    return new Response('arti', { status: 206, headers: { 'content-length': '4', 'content-range': 'bytes 0-3/14', 'accept-ranges': 'bytes' } });
  };
  const partial = await f.send('GET', `/api/builds/${id}/artifacts/0`, undefined, undefined, { range: 'bytes=0-3' });
  assert.equal(partial.statusCode, 206);
  assert.equal(partial.body, 'arti');
  assert.equal(partial.headers['content-range'], 'bytes 0-3/14');
  assert.equal(partial.headers['content-length'], '4');
  f.remotes.artifact = async () => new Response('dufs-link', {
    headers: { 'content-encoding': 'gzip', 'content-length': '29' }
  });
  const decoded = await f.send('GET', `/api/builds/${id}/artifacts/0`);
  assert.equal(decoded.body, 'dufs-link');
  assert.equal(decoded.headers['content-length'], undefined);
  assert.equal((await f.send('GET', `/api/builds/${id}/artifacts/10`)).statusCode, 404);
});
test('uncertain submission is recorded and never automatically retriggered', async t => {
  const f = await fixture(t); let posts = 0;
  f.remotes.trigger = async () => { posts++; throw new Error('timeout'); };
  const response = (await f.send('POST', '/api/builds', build)).json();
  assert.equal(response.status, 'UNKNOWN');
  assert.equal((await f.send('POST', '/api/builds', build)).json().id, response.id);
  assert.equal(posts, 1);
});
test('Jenkins CSRF rejection is recorded distinctly from uncertain submissions', async t => {
  const f = await fixture(t);
  f.remotes.trigger = remoteClients(config, async () => new Response('No valid crumb was included in the request', { status: 403 })).trigger;
  const row = (await f.send('POST', '/api/builds', build)).json();
  assert.equal(row.status, 'REJECTED');
  assert.match(row.error, /API Token/);
  assert.equal(row.queue_id, null);
});

test('reject missing branch, unsupported format, and wrong Play key', async t => {
  const f = await fixture(t);
  assert.equal((await f.send('POST', '/api/builds', { ...build, branch: 'missing' })).statusCode, 400);
  assert.equal((await f.send('POST', '/api/builds', { ...build, format: 'aab' })).statusCode, 400);
  const phone = projects.find(p => p.id === 'tappo-phone');
  assert.throws(() => buildParameters(phone, { branch: 'qc', environment: 'prod', format: 'aab' }), /上传密钥/);
  const parameters = buildParameters(phone, { branch: 'qc', environment: 'prod', format: 'aab', signingKey: 'phone-key', versionCode: '123' }, config.signingKeys['tappo-phone']);
  assert.equal(parameters.SIGNING_KEY, 'phone-key');
  assert.equal(parameters.VERSION_CODE, '123');
  const hpos = projects.find(p => p.id === 'hpos');
  assert.equal(buildParameters(hpos, { branch: 'qc', environment: 'pre-prod', format: 'apk' }).BUILD_TYPE, 'pre-prod');
});
test('remote clients encode job paths, paginate branches and disable credential redirects', async () => {
  const calls = [];
  const remotes = remoteClients(config, async (url, options) => {
    calls.push({ url, options });
    if (url.includes('/repository/branches')) return Response.json([{ name: url.endsWith('page=1') ? 'qc' : 'feature/abc' }], { headers: { 'x-next-page': url.endsWith('page=1') ? '2' : '' } });
    return new Response('', { status: 201, headers: { location: 'http://internal/queue/item/9/' } });
  });
  assert.deepEqual(await remotes.branches(projects[0]), ['feature/abc', 'qc']);
  assert.equal(await remotes.trigger('folder/TOA POS', { BRANCH: 'feature/a' }), 9);
  assert.match(calls[2].url, /job\/folder\/job\/TOA%20POS/);
  assert.equal(calls[2].options.redirect, 'manual');
  assert.equal(calls[2].options.body.get('BRANCH'), 'feature/a');
});

test('artifact fetch starts with GET without an extra HEAD request', async () => {
  const calls = [];
  const remotes = remoteClients(config, async (url, options) => {
    calls.push({ url, method: options.method || 'GET' });
    return new Response('https://dufs.test/installer.apk\n');
  });
  const response = await remotes.artifact('folder/TOA POS', 13, 'links/dufs-links.txt');
  assert.equal(await response.text(), 'https://dufs.test/installer.apk\n');
  assert.deepEqual(calls, [{
    url: 'http://jenkins.test/job/folder/job/TOA%20POS/13/artifact/links/dufs-links.txt',
    method: 'GET'
  }]);
});

test('concurrent duplicate requests dispatch once and preserve actor boundary', async t => {
  const f = await fixture(t);
  const results = await Promise.all([f.send('POST', '/api/builds', build), f.send('POST', '/api/builds', build)]);
  assert.equal(results[0].json().id, results[1].json().id);
  assert.equal(f.count(), 1);
  const tester = await f.login('tester');
  assert.equal((await f.send('POST', '/api/builds', build, tester)).statusCode, 409);
});

test('Jenkins activity reads queued Pipeline steps and occupied executors', async () => {
  const calls = [];
  const remotes = remoteClients(config, async url => {
    calls.push(url);
    if (url.includes('/queue/api/json')) return Response.json({ items: [
      { id: 175, task: { name: 'part of TOA-KIOSK-WINDOWS #21', url: 'job/TOA-KIOSK-WINDOWS/21/' } }
    ] });
    return Response.json({ computer: [
      { numExecutors: 2, offline: false, executors: [{ currentExecutable: { url: 'job/A/1/' } }, { currentExecutable: { url: 'job/B/2/' } }] },
      { numExecutors: 1, offline: true, executors: [] }
    ] });
  });
  const [first, second] = await Promise.all([remotes.jenkinsActivity(), remotes.jenkinsActivity()]);
  assert.equal(first, second);
  assert.equal(first.capacity, 2);
  assert.equal(first.running, 2);
  assert.equal(first.queue[0].task.url, 'job/TOA-KIOSK-WINDOWS/21/');
  assert.equal(calls.length, 2);
});

test('queue status combines active builds across projects without exposing request payloads', async t => {
  const f = await fixture(t, { allowGuestBuilds: true });
  const queued = (await f.send('POST', '/api/builds', build)).json();
  f.store.db.prepare('INSERT INTO builds(request_id,project,actor,created,payload,job,status,number) VALUES(?,?,?,?,?,?,?,?)').run(
    'other-queue-request', 'hpos', 'tester', new Date().toISOString(),
    JSON.stringify({ name: '手持需求', branch: 'qc' }), 'TOA-HPOS-Android', 'RUNNING', 21
  );
  f.remotes.jenkinsActivity = async () => ({
    capacity: 2, running: 2,
    queue: [
      { id: 175, task: { name: 'part of TOA-HPOS-Android #21', url: 'job/TOA-HPOS-Android/21/' } },
      { id: 176, task: { name: 'private Jenkins job', url: 'job/PRIVATE/1/' } }
    ]
  });
  const response = await f.app.inject('/api/builds/queue-status');
  assert.equal(response.statusCode, 200);
  const queue = response.json();
  assert.equal(queue.capacity, 2);
  assert.equal(queue.running, 2);
  assert.equal(queue.waiting, 2);
  assert.deepEqual(queue.items.map(item => item.status), ['QUEUED', 'QUEUED', 'QUEUED']);
  assert.equal(queue.items[0].id, queued.id);
  assert.equal(queue.items[1].name, '手持需求');
  assert.equal(queue.items[1].waitingForExecutor, true);
  assert.equal('payload' in queue.items[1], false);
  assert.equal(queue.items[2].name, '其他 Jenkins 等待任务');
  const hpos = (await f.send('GET', '/api/builds?project=hpos')).json();
  assert.equal(hpos[0].status, 'QUEUED');
  assert.equal(hpos[0].waitingForExecutor, true);
});

test('route guards reject anonymous encoded API paths and logout invalidates sessions', async t => {
  const f = await fixture(t);
  for (const url of ['/api/projects', '/api/projects?x=1', '/%61pi/projects', '/api%2fprojects']) {
    assert.notEqual((await f.app.inject(url)).statusCode, 200);
  }
  assert.equal((await f.send('POST', '/api/logout')).statusCode, 200);
  assert.equal((await f.send('GET', '/api/projects')).statusCode, 401);
});

test('TOA builds disable Incident even when an old client requests it', () => {
  const project = projects.find(p => p.id === 'toa-pos');
  for (const incident of [undefined, false, true]) {
    const parameters = buildParameters(project, { branch: 'devlop_qc', environment: 'test-prod', format: 'exe', upload: true, notify: true, incident });
    assert.equal(parameters.ENABLE_INCIDENT_UPLOAD, 'false');
    assert.equal(parameters.UPLOAD_DUFS, 'true');
    assert.equal(parameters.SEND_DINGTALK, 'true');
  }
});

test('personal memos enforce ownership, validate input, and preserve newer edits', async t => {
  const f = await fixture(t, {
    allowGuestBuilds: true,
    users: [...config.users, { ...config.users[0], username: 'other-admin' }]
  });
  const tester = await f.login('other-admin');
  const builder = await f.login('tester');
  const id = 'a'.repeat(32), path = '/api/memos/' + id;
  const draft = { title: '常用命令', content: 'echo "<script>test</script>"\n  keep spaces\n', revision: 0 };
  assert.equal((await f.send('GET', '/api/memos', undefined, '')).statusCode, 403);
  assert.equal((await f.send('PUT', path, draft, '')).statusCode, 403);
  assert.equal((await f.send('PUT', path, { ...draft, title: ' ' })).statusCode, 400);
  assert.equal((await f.send('PUT', path, { ...draft, content: 'x'.repeat(20001) })).statusCode, 400);
  assert.equal((await f.send('PUT', '/api/memos/invalid', draft)).statusCode, 400);
  assert.equal((await f.send('GET', '/api/memos', undefined, builder)).statusCode, 403);
  assert.equal((await f.send('PUT', path, draft, builder)).statusCode, 403);
  assert.equal((await f.send('DELETE', path, { revision: 1 }, builder)).statusCode, 403);
  const saved = (await f.send('PUT', path, draft, tester)).json();
  assert.equal(saved.revision, 1);
  assert.equal(saved.content, draft.content);
  // Even administrators cannot access another account's memos.
  assert.deepEqual((await f.send('GET', '/api/memos')).json(), []);
  assert.equal((await f.send('GET', '/api/memos', undefined, tester)).json()[0].id, id);
  assert.equal((await f.send('PUT', path, { ...draft, revision: 1 })).statusCode, 404);
  assert.equal((await f.send('DELETE', path, { revision: 1 })).statusCode, 404);
  assert.equal((await f.send('PUT', path, draft, tester)).statusCode, 409);
  const updated = (await f.send('PUT', path, { ...draft, revision: 1, content: 'changed' }, tester)).json();
  assert.equal(updated.revision, 2);
  assert.equal((await f.send('DELETE', path, { revision: 1 }, tester)).statusCode, 409);
  assert.equal((await f.send('DELETE', path, { revision: 2 }, '')).statusCode, 403);
  assert.equal((await f.send('DELETE', path, { revision: 2 }, tester)).statusCode, 200);
  assert.deepEqual((await f.send('GET', '/api/memos', undefined, tester)).json(), []);
  assert.equal((await f.send('PUT', path, updated, tester)).statusCode, 409);
});

test('memos persist across database reopening without changing existing tables', async t => {
  const { mkdtempSync, rmSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const directory = mkdtempSync(join(tmpdir(), 'platform-memos-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const path = join(directory, 'data.sqlite');
  const first = openStore(path);
  first.db.prepare('INSERT INTO memos VALUES(?,?,?,?,?,?)').run('b'.repeat(32), 'tester', 'Command', 'git status\n', 1, '2026-09-30');
  first.close();
  const reopened = openStore(path);
  try {
    assert.equal(reopened.db.prepare('SELECT content FROM memos WHERE owner=?').get('tester').content, 'git status\n');
    assert.equal(reopened.db.prepare('SELECT count(*) AS count FROM builds').get().count, 0);
  } finally { reopened.close(); }
});
