import { randomBytes, scryptSync, timingSafeEqual } from 'node:crypto';
import { fail } from './projects.js';

export function hashPassword(password) {
  const salt = randomBytes(16).toString('hex');
  return `${salt}:${scryptSync(password, salt, 64).toString('hex')}`;
}
export function checkPassword(password, stored) {
  const [salt, hash] = String(stored).split(':');
  if (!salt || !/^[a-f0-9]{128}$/.test(hash || '')) return false;
  return timingSafeEqual(Buffer.from(hash, 'hex'), scryptSync(password, salt, 64));
}
export function authentication(app, config) {
  const sessions = new Map();
  const attempts = new Map();
  const dummyHash = hashPassword(randomBytes(32).toString('hex'));
  const cookie = { path: '/', httpOnly: true, secure: config.secureCookies, sameSite: 'strict' };
  const cleanup = setInterval(() => {
    const now = Date.now();
    for (const [id, session] of sessions) if (session.expires < now) sessions.delete(id);
    for (const [id, attempt] of attempts) if (attempt.until < now) attempts.delete(id);
  }, 60000).unref();
  app.addHook('onClose', async () => clearInterval(cleanup));
  app.addHook('preHandler', async request => {
    const route = request.routeOptions.url || '';
    if (!route.startsWith('/api/')) return;
    if (!['GET', 'HEAD'].includes(request.method)) {
      if (request.headers.origin !== config.publicOrigin || request.headers['x-platform-request'] !== '1') fail('请求来源不受信任', 403);
    }
    if (route === '/api/login') return;
    const session = sessions.get(request.cookies.session);
    if (!session || session.expires < Date.now()) fail('请登录', 401);
    request.user = session.user;
  });
  app.post('/api/login', async (request, reply) => {
    const { username, password } = request.body || {};
    if (typeof username !== 'string' || typeof password !== 'string' || password.length > 256) fail('账号或密码错误', 401);
    const key = request.ip;
    let attempt = attempts.get(key);
    if (!attempt || attempt.until < Date.now()) attempt = { count: 0, until: Date.now() + 15 * 60000 };
    attempts.set(key, attempt);
    if (attempt.count >= 10) fail('登录尝试过多，请 15 分钟后重试', 429);
    attempt.count++;
    const account = config.users.find(user => user.username === username);
    const valid = checkPassword(password, account?.passwordHash || dummyHash);
    if (!account || !valid) fail('账号或密码错误', 401);
    attempts.delete(key);
    const user = { username: account.username, role: account.role };
    const token = randomBytes(32).toString('hex');
    sessions.delete(request.cookies.session);
    sessions.set(token, { user, expires: Date.now() + 8 * 3600000 });
    reply.setCookie('session', token, { ...cookie, maxAge: 8 * 3600 });
    return user;
  });
  app.get('/api/me', async request => request.user);
  app.post('/api/logout', async (request, reply) => {
    sessions.delete(request.cookies.session);
    reply.clearCookie('session', cookie);
    return { ok: true };
  });
}
