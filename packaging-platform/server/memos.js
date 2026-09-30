import { fail } from './projects.js';

export function memoRoutes(app, db) {
  const owner = request => {
    if (request.user.role === 'guest') fail('请登录后使用个人备忘录', 403);
    return request.user.username;
  };
  const memoId = request => {
    if (!/^[a-f0-9]{32}$/.test(request.params.id)) fail('无效备忘录编号');
    return request.params.id;
  };
  app.get('/api/memos', async request => db.prepare(
    'SELECT id,title,content,revision,updated FROM memos WHERE owner=? ORDER BY updated DESC,id'
  ).all(owner(request)));
  app.put('/api/memos/:id', { bodyLimit: 131072 }, async request => {
    const username = owner(request), id = memoId(request);
    const { title, content, revision } = request.body || {};
    if (typeof title !== 'string' || !title.trim() || title.length > 100 ||
        typeof content !== 'string' || content.length > 20000 ||
        !Number.isSafeInteger(revision) || revision < 0) fail('请填写标题（最多100字）和内容（最多20000字）');
    const previous = db.prepare('SELECT owner,revision FROM memos WHERE id=?').get(id);
    if (previous && previous.owner !== username) fail('备忘录不存在', 404);
    if ((previous?.revision || 0) !== revision) fail('备忘录已更新或删除，请保留当前内容并刷新列表', 409);
    const updated = new Date().toISOString();
    if (previous) {
      db.prepare('UPDATE memos SET title=?,content=?,revision=revision+1,updated=? WHERE id=? AND owner=?')
        .run(title.trim(), content, updated, id, username);
    } else {
      db.prepare('INSERT INTO memos VALUES(?,?,?,?,?,?)').run(id, username, title.trim(), content, 1, updated);
    }
    return { id, title: title.trim(), content, revision: revision + 1, updated };
  });
  app.delete('/api/memos/:id', async request => {
    const username = owner(request), id = memoId(request);
    const revision = request.body?.revision;
    if (!Number.isSafeInteger(revision) || revision < 1) fail('无效备忘录版本');
    const previous = db.prepare('SELECT revision FROM memos WHERE id=? AND owner=?').get(id, username);
    if (!previous) fail('备忘录不存在', 404);
    if (previous.revision !== revision) fail('备忘录已更新，请刷新后再删除', 409);
    db.prepare('DELETE FROM memos WHERE id=? AND owner=?').run(id, username);
    return { ok: true };
  });
}
