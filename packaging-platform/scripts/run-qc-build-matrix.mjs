import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';

const base = process.env.PLATFORM_URL || 'http://127.0.0.1:3100';
const origin = process.env.PLATFORM_ORIGIN || 'http://package.zj2.natnps.cn';
const runId = process.env.QC_MATRIX_RUN_ID || '2026-10-01';
const branch = process.env.QC_MATRIX_BRANCH || 'devlop_qc';
const selectedKeys = new Set((process.env.QC_MATRIX_KEYS || '').split(',').filter(Boolean));
const output = resolve(`data/qc-build-matrix-${runId}.json`);
const report = resolve(`data/qc-build-matrix-${runId}.md`);
const terminal = new Set(['SUCCESS', 'FAILURE', 'ABORTED', 'CANCELLED', 'REJECTED', 'UNKNOWN', 'UNSTABLE']);
const matrix = [
  ['toa-pos', 'exe', null, ['test-prod', 'pre-prod', 'release', 'debug', 'release-debug']],
  ['kiosk', 'exe', 'kiosk', ['staging', 'test-prod', 'release', 'debug']],
  ['hpos', 'apk', null, ['test-prod', 'pre-prod', 'release', 'debug']],
  ['tappo', 'apk', null, ['qc', 'beta', 'gray', 'release']],
  ['tappo-phone', 'apk', null, ['qc', 'prod']],
];

const plan = matrix.flatMap(([project, format, product, environments]) => environments.map(environment => ({
  key: `${project}:${environment}:${format}`,
  project, environment, format, ...(product ? { product } : {}),
  branch, upload: true, notify: false,
  signingKey: '', versionCode: '',
  requestId: `qc-matrix-${runId}-${project}-${environment}-${format}`,
  status: 'PENDING'
}))).filter(item => selectedKeys.size === 0 || selectedKeys.has(item.key));

async function request(path, options = {}) {
  const response = await fetch(base + '/api' + path, {
    signal: AbortSignal.timeout(45_000),
    ...options,
    headers: { 'X-Platform-Request': '1', Origin: origin, ...(options.body ? { 'Content-Type': 'application/json' } : {}), ...options.headers }
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(`${response.status} ${body.error || response.statusText}`);
  return body;
}

async function loadState() {
  try {
    const saved = JSON.parse(await readFile(output, 'utf8'));
    return { ...saved, entries: plan.map(item => {
      const restored = { ...item, ...saved.entries?.find(entry => entry.key === item.key) };
      const retryableSubmissionFailure = restored.error?.includes('请求来源不受信任')
        || restored.error?.includes('外部服务暂不可用');
      if (!restored.buildId && restored.status === 'REJECTED' && retryableSubmissionFailure) {
        restored.status = 'PENDING';
        delete restored.error;
        delete restored.finishedAt;
      }
      return restored;
    }) };
  } catch {
    return { startedAt: new Date().toISOString(), entries: plan };
  }
}

function markdown(state) {
  const names = { 'toa-pos': 'TOA POS · Windows', kiosk: '自助收银 · Windows', hpos: '手持 POS · Android', tappo: 'Tappo · Android', 'tappo-phone': 'Tappo Phone · Android' };
  const counts = state.entries.reduce((groups, item) => {
    (groups[item.status] ||= []).push(item);
    return groups;
  }, {});
  const rows = state.entries.map(item => {
    const artifact = item.artifacts?.filter(value => value.fileName !== 'dufs-links.txt').map(value => value.fileName).join('<br>') || '—';
    const dufs = item.dufsLinks?.map(value => `[下载](${value})`).join('<br>') || '—';
    return `| ${names[item.project]} | ${item.environment} | ${item.format.toUpperCase()} | ${item.status} | ${item.number || '—'} | ${artifact} | ${dufs} |`;
  });
  return `# ${branch} 分支多环境构建测试报告\n\n- 分支：\`${branch}\`\n- 开始时间：${state.startedAt}\n- 完成时间：${state.finishedAt || '执行中'}\n- 结果：${Object.entries(counts).map(([key, values]) => `${key} ${values.length}`).join('，')}\n\n| 项目 | 环境 | 格式 | 结果 | Jenkins | 产物 | DUFS |\n|---|---|---|---|---:|---|---|\n${rows.join('\n')}\n`;
}

async function save(state) {
  await mkdir(dirname(output), { recursive: true });
  await writeFile(output, JSON.stringify(state, null, 2));
  await writeFile(report, markdown(state));
}

const state = await loadState();
await save(state);

while (state.entries.some(item => !terminal.has(item.status))) {
  for (const item of state.entries.filter(value => value.buildId && !terminal.has(value.status))) {
    try {
      const build = await request(`/builds/${item.buildId}`);
      item.status = build.status;
      item.number = build.number;
      item.error = build.error;
      item.artifacts = build.artifacts || [];
      item.updatedAt = new Date().toISOString();
      if (terminal.has(item.status)) {
        item.finishedAt = item.updatedAt;
        if (item.status === 'SUCCESS') {
          item.publicLinks = item.artifacts
            .map((artifact, index) => ({ artifact, index }))
            .filter(({ artifact }) => artifact.fileName !== 'dufs-links.txt')
            .map(({ index }) => `${build.publicOrigin}/api/builds/${build.id}/artifacts/${index}`);
          try { item.dufsLinks = (await request(`/builds/${build.id}/dufs-links`)).links || []; }
          catch (error) { item.dufsError = error.message; }
        }
        console.log(`[完成] ${item.key} -> ${item.status} Jenkins #${item.number || '?'}`);
      }
    } catch (error) {
      item.pollError = error.message;
    }
  }

  let queue;
  try { queue = await request('/builds/queue-status'); }
  catch (error) { console.log(`[队列读取失败] ${error.message}`); await save(state); await new Promise(resolveDelay => setTimeout(resolveDelay, 15_000)); continue; }

  let free = Math.max(0, queue.capacity - queue.running - queue.waiting);
  const pending = state.entries.filter(value => value.status === 'PENDING');
  const activeProjects = new Set(state.entries
    .filter(value => value.buildId && !terminal.has(value.status))
    .map(value => value.project));
  const submissions = [];
  while (free > 0 && pending.length > 0) {
    let index = pending.findIndex(value => !activeProjects.has(value.project));
    if (index < 0) index = 0;
    const [item] = pending.splice(index, 1);
    submissions.push(item);
    activeProjects.add(item.project);
    free -= 1;
  }
  for (const item of submissions) {
    try {
      const build = await request('/builds', { method: 'POST', body: JSON.stringify(item) });
      item.buildId = build.id;
      item.status = build.status;
      item.submittedAt = new Date().toISOString();
      item.error = build.error;
      console.log(`[提交] ${item.key} -> 平台 #${item.buildId} (${item.status})`);
    } catch (error) {
      if (error.message.includes('外部服务暂不可用')) {
        item.status = 'PENDING';
        item.submissionError = error.message;
        console.log(`[提交暂缓] ${item.key} -> ${error.message}`);
      } else {
        item.status = 'REJECTED';
        item.error = error.message;
        item.finishedAt = new Date().toISOString();
        console.log(`[提交失败] ${item.key} -> ${error.message}`);
      }
    }
  }

  await save(state);
  const remaining = state.entries.filter(item => !terminal.has(item.status)).length;
  const active = state.entries.filter(item => item.buildId && !terminal.has(item.status)).map(item => `${item.key}:${item.status}`).join(', ');
  console.log(`[进度] 剩余 ${remaining}/${state.entries.length}${active ? `；测试中 ${active}` : ''}`);
  if (remaining) await new Promise(resolveDelay => setTimeout(resolveDelay, 15_000));
}

state.finishedAt = new Date().toISOString();
await save(state);
console.log(`[全部完成] 报告：${report}`);
