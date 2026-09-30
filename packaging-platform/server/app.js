import Fastify from 'fastify';
import cookie from '@fastify/cookie';
import staticFiles from '@fastify/static';
import { Readable } from 'node:stream';
import { existsSync } from 'node:fs';
import { authentication } from './auth.js';
import { projects, buildParameters, fail } from './projects.js';

export async function createApp({ config, store, remotes, staticRoot }) {
  const app = Fastify({ bodyLimit: 16384, logger: false });
  const { db, audit } = store;
  const catalog = projects.map(project => ({ ...project, job: config.jenkins.jobs?.[project.id] || project.job }));
  const projectById = id => catalog.find(project => project.id === id) || fail('项目不存在', 404);
  const buildById = id => db.prepare('SELECT * FROM builds WHERE id=?').get(id) || fail('构建不存在', 404);
  const redact = text => [config.jenkins.token, config.gitlab.token].filter(Boolean).reduce((value, token) => value.split(token).join('****'), text);
  app.setErrorHandler((error, request, reply) => {
    const status = error.statusCode || 502;
    reply.code(status).send({ error: status < 500 ? error.message : '外部服务暂不可用，请检查 Jenkins / GitLab 地址、凭据和网络。' });
  });
  app.addHook('onSend', async (request, reply) => {
    reply.header('X-Content-Type-Options', 'nosniff');
    reply.header('Referrer-Policy', 'no-referrer');
    reply.header('X-Frame-Options', 'DENY');
    reply.header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'");
    if (request.url.startsWith('/api/')) reply.header('Cache-Control', 'no-store');
  });
  await app.register(cookie);
  authentication(app, config);
  app.get('/api/projects', async () => catalog.map(({ id, name, environments, formats, products, signing, incident }) => ({
    id, name, environments, formats, products, signing, incident, signingKeys: config.signingKeys?.[id] || []
  })));
  app.get('/api/projects/:project/branches', async request => {
    const project = projectById(request.params.project);
    const names = await remotes.branches(project);
    const notes = db.prepare('SELECT * FROM notes WHERE project=?').all(project.id);
    return names.map(branch => ({ branch, ...notes.find(note => note.branch === branch) }));
  });
  app.put('/api/projects/:project/notes', async request => {
    if (request.user.role !== 'admin') fail('仅管理员可维护分支说明', 403);
    const project = projectById(request.params.project);
    const { branch, name, description, updated } = request.body || {};
    if (typeof branch !== 'string' || typeof name !== 'string' || !name.trim() || name.length > 80 || typeof description !== 'string' || description.length > 2000) fail('请填写有效需求名称和说明');
    if (!(await remotes.branches(project)).includes(branch)) fail('远端分支已不存在');
    const previous = db.prepare('SELECT updated FROM notes WHERE project=? AND branch=?').get(project.id, branch);
    if ((previous?.updated || '') !== (updated || '')) fail('说明已被其他人修改，请刷新后重试', 409);
    const now = new Date().toISOString();
    db.prepare('INSERT OR REPLACE INTO notes VALUES(?,?,?,?,?,?)').run(project.id, branch, name.trim(), description.trim(), request.user.username, now);
    audit(request.user.username, 'edit-note', { project: project.id, branch, name, description });
    return { updated: now };
  });
  app.post('/api/builds', async (request, reply) => {
    if (config.previewBranchesOnly) fail('真实分支预览暂不支持 Jenkins 构建，请配置正式服务后使用。', 403);
    const input = request.body || {};
    if (!/^[a-zA-Z0-9-]{16,80}$/.test(input.requestId || '')) fail('请求标识无效');
    const previous = db.prepare('SELECT * FROM builds WHERE request_id=?').get(input.requestId);
    if (previous) {
      if (previous.actor !== request.user.username) fail('请求标识冲突', 409);
      return previous;
    }
    const project = projectById(input.project);
    const parameters = buildParameters(project, input, config.signingKeys?.[project.id] || []);
    if (!(await remotes.branches(project)).includes(input.branch)) fail('分支不存在，请刷新列表');
    const note = db.prepare('SELECT name FROM notes WHERE project=? AND branch=?').get(project.id, input.branch);
    const payload = { ...input, name: note?.name || input.branch, parameters };
    // Reserve before POST: a timeout may mean Jenkins accepted the request. Never auto-resubmit.
    let id;
    try {
      id = Number(db.prepare('INSERT INTO builds(request_id,project,actor,created,payload,job,status) VALUES(?,?,?,?,?,?,?)').run(
        input.requestId, project.id, request.user.username, new Date().toISOString(), JSON.stringify(payload), project.job, 'SUBMITTING'
      ).lastInsertRowid);
    } catch (error) {
      const existing = db.prepare('SELECT * FROM builds WHERE request_id=?').get(input.requestId);
      if (!existing || existing.actor !== request.user.username) throw error;
      return existing;
    }
    audit(request.user.username, 'build-request', { id, project: project.id, parameters });
    try {
      const queue = await remotes.trigger(project.job, parameters);
      db.prepare('UPDATE builds SET queue_id=?,status=? WHERE id=?').run(queue, 'QUEUED', id);
    } catch (error) {
      db.prepare('UPDATE builds SET status=?,error=? WHERE id=?').run(
        error.submissionRejected ? 'REJECTED' : 'UNKNOWN',
        error.submissionRejected ? redact(error.message) : '提交结果未确认。请管理员在 Jenkins 核对，避免重复构建。', id
      );
    }
    reply.code(201);
    return buildById(id);
  });
  app.get('/api/builds', async request => {
    projectById(request.query.project);
    return db.prepare('SELECT * FROM builds WHERE project=? ORDER BY id DESC LIMIT 100').all(request.query.project);
  });
  async function refresh(row) {
    if (!['QUEUED', 'RUNNING'].includes(row.status)) return row;
    try {
      if (!row.number) {
        const queue = await remotes.queue(row.queue_id);
        if (queue.cancelled) db.prepare('UPDATE builds SET status=?,error=NULL WHERE id=?').run('CANCELLED', row.id);
        else if (queue.executable?.number) db.prepare('UPDATE builds SET number=?,status=?,error=NULL WHERE id=?').run(queue.executable.number, 'RUNNING', row.id);
      }
      row = buildById(row.id);
      if (row.number) {
        const build = await remotes.build(row.job, row.number);
        db.prepare('UPDATE builds SET status=?,result=?,error=NULL WHERE id=?').run(build.building ? 'RUNNING' : (build.result || 'UNKNOWN'), build.result, row.id);
      }
    } catch {
      db.prepare('UPDATE builds SET error=? WHERE id=?').run('暂时无法同步 Jenkins 状态；任务可能仍在运行，请勿重复提交。', row.id);
    }
    return buildById(row.id);
  }
  app.get('/api/builds/:id', async request => {
    const row = await refresh(buildById(request.params.id));
    let artifacts = [];
    if (row.number) {
      try { artifacts = (await remotes.build(row.job, row.number)).artifacts || []; }
      catch { return { ...row, artifacts, error: row.error || '产物信息暂时无法读取' }; }
    }
    return { ...row, artifacts };
  });
  app.get('/api/builds/:id/log', async request => {
    const row = buildById(request.params.id);
    const start = Number(request.query.start || 0);
    if (!Number.isSafeInteger(start) || start < 0) fail('无效日志偏移');
    if (!row.number) return { text: '等待 Jenkins 分配构建编号。', next: start, more: false };
    const log = await remotes.log(row.job, row.number, start);
    return { ...log, text: redact(log.text) };
  });
  app.get('/api/builds/:id/artifacts/:index', async (request, reply) => {
    const row = buildById(request.params.id);
    if (!row.number) fail('构建尚无产物', 404);
    const index = Number(request.params.index);
    if (!Number.isSafeInteger(index) || index < 0) fail('无效产物');
    const build = await remotes.build(row.job, row.number);
    const artifact = build.artifacts?.[index];
    if (!artifact || artifact.relativePath.split('/').some(part => part === '..') || artifact.relativePath.includes('\\')) fail('产物不存在', 404);
    const range = request.headers.range;
    if (range && !/^bytes=\d+-\d*$/.test(range)) fail('无效下载范围');
    const response = await remotes.artifact(row.job, row.number, artifact.relativePath, range);
    if (response.status !== 200 && response.status !== 206) fail('Jenkins 未能提供产物', 502);
    reply.code(response.status);
    reply.header('Content-Type', 'application/octet-stream');
    reply.header('Content-Disposition', `attachment; filename*=UTF-8''${encodeURIComponent(artifact.fileName)}`);
    // Node fetch transparently decompresses Jenkins responses. Its original
    // Content-Length then describes compressed bytes, not the streamed body.
    const decoded = response.headers.get('content-encoding') && response.headers.get('content-encoding') !== 'identity';
    for (const header of ['content-length', 'content-range', 'accept-ranges']) {
      if (decoded && header === 'content-length') continue;
      const value = response.headers.get(header) || (header === 'content-length' ? response.verifiedLength : null);
      if (value) reply.header(header, value);
    }
    return reply.send(Readable.fromWeb(response.body));
  });
  if (staticRoot && existsSync(staticRoot)) await app.register(staticFiles, { root: staticRoot });
  // One lightweight poller for the single Windows-host deployment.
  let polling = false;
  const timer = setInterval(async () => {
    if (polling) return;
    polling = true;
    try {
      for (const row of db.prepare("SELECT * FROM builds WHERE status IN ('QUEUED','RUNNING')").all()) await refresh(row);
    } finally { polling = false; }
  }, 10000).unref();
  app.addHook('onClose', async () => clearInterval(timer));
  return app;
}
