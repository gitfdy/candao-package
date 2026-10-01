import test from 'node:test';
import assert from 'node:assert/strict';
import { readRoute, routeUrl } from '../web/navigation.js';
import { downloads, startDownload, cancelDownload, dismissDownload, downloadBuildArtifact } from '../web/download.js';

test('shared build addresses survive parsing and reject invalid build identifiers', () => {
  const route = { project: 'toa-pos-windows', page: 'history', build: 14 };
  const path = routeUrl(route, 'http://package.zj2.natnps.cn/?source=share');
  assert.deepEqual(readRoute(new URL(path, 'http://localhost').search), route);
  assert.equal(new URL(path, 'http://localhost').searchParams.get('source'), 'share');
  for (const id of ['-1', '0', '1/../../login', '1.5', '9007199254740993']) assert.equal(readRoute(`?page=history&build=${id}`).build, null);
  assert.equal(readRoute('?page=build&build=14').build, null);
  assert.equal(readRoute('?page=unknown').page, 'build');
  assert.equal(new URL(routeUrl({ ...route, page: 'build' }, `http://localhost${path}`), 'http://localhost').searchParams.has('build'), false);
});

function browserStubs(t) {
  const saved = [];
  const oldDocument = globalThis.document;
  globalThis.document = { body: { append() {} }, createElement() { return { click() { saved.push(this.download); }, remove() {} }; } };
  t.after(() => { if (oldDocument === undefined) delete globalThis.document; else globalThis.document = oldDocument; });
  t.mock.method(URL, 'createObjectURL', () => 'blob:test');
  t.mock.method(URL, 'revokeObjectURL', () => {});
  t.mock.timers.enable({ apis: ['setTimeout'] });
  return saved;
}

test('artifact download assembles ranges in order and saves the original filename', async t => {
  const saved = browserStubs(t), requested = [], percentages = [];
  const total = 4 * 1024 * 1024 + 3;
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    assert.equal(url, '/api/builds/14/artifacts/0');
    const [, start, end] = /^bytes=(\d+)-(\d+)$/.exec(options.headers.Range);
    requested.push(Number(start));
    const last = Math.min(Number(end), total - 1);
    return new Response(new Uint8Array(last - Number(start) + 1), { status: 206, headers: { 'content-range': `bytes ${start}-${last}/${total}` } });
  });
  await downloadBuildArtifact(14, { fileName: 'package.exe' }, 0, (_, percent) => { if (percent !== undefined) percentages.push(percent); });
  assert.deepEqual(requested, [0, 4 * 1024 * 1024]);
  assert.equal(percentages.at(-1), 100);
  assert.deepEqual(saved, ['package.exe']);
});

test('download manager deduplicates active requests and cancels the network request', async t => {
  const saved = browserStubs(t);
  const fetchMock = t.mock.method(globalThis, 'fetch', (url, { signal }) => new Promise((resolve, reject) => {
    signal.addEventListener('abort', () => reject(signal.reason), { once: true });
  }));
  const taskPromise = startDownload(15, { fileName: 'package.exe' }, 0);
  startDownload(15, { fileName: 'package.exe' }, 0);
  assert.equal(fetchMock.mock.callCount(), 1);
  assert.equal(downloads.find(task => task.key === '15:0').status, 'running');
  dismissDownload('15:0');
  assert.equal(downloads.length, 1);
  cancelDownload('15:0');
  await taskPromise;
  assert.equal(downloads[0].status, 'cancelled');
  assert.deepEqual(saved, []);
  dismissDownload('15:0');
  assert.equal(downloads.length, 0);
});

test('failed downloads can be retried without duplicating the global task', async t => {
  const saved = browserStubs(t);
  t.mock.method(globalThis, 'fetch', async () => new Response('', { status: 404 }));
  await startDownload(16, { fileName: 'retry.exe' }, 0);
  assert.equal(downloads[0].status, 'failed');
  t.mock.method(globalThis, 'fetch', async () => new Response(new Uint8Array(3), { status: 206, headers: { 'content-range': 'bytes 0-2/3' } }));
  await startDownload(16, { fileName: 'retry.exe' }, 0);
  assert.equal(downloads.length, 1);
  assert.equal(downloads[0].status, 'complete');
  assert.deepEqual(saved, ['retry.exe']);
  dismissDownload('16:0');
});

test('invalid artifact ranges stop immediately rather than saving a corrupt file', async t => {
  const saved = browserStubs(t);
  const fetchMock = t.mock.method(globalThis, 'fetch', async () => new Response(new Uint8Array(3), { status: 206, headers: { 'content-range': 'bytes 1-3/4' } }));
  await assert.rejects(downloadBuildArtifact(14, { fileName: 'package.exe' }, 0), /下载范围响应无效/);
  assert.equal(fetchMock.mock.callCount(), 1);
  assert.deepEqual(saved, []);
});
