import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { createInterface } from 'node:readline/promises';
import { fileURLToPath } from 'node:url';
import { hashPassword } from '../server/auth.js';

const path = fileURLToPath(new URL('../config.local.json', import.meta.url));
if (!existsSync(path)) throw new Error('先复制 config.example.json 为 config.local.json');
const config = JSON.parse(readFileSync(path, 'utf8'));
config.users ||= [];
const resetUsername = process.argv[2] === '--reset' ? (process.argv[3] || '').trim() : '';
const input = createInterface({ input: process.stdin, output: process.stdout });
const username = resetUsername || (await input.question('用户名：')).trim();
const existing = config.users.find(user => user.username === username);
const role = resetUsername ? existing?.role : (await input.question('角色 admin / builder：')).trim();
input.close();
if (!/^[a-zA-Z0-9._-]{2,40}$/.test(username) || !['admin', 'builder'].includes(role)) throw new Error('用户名或角色无效');
if (resetUsername && !existing) throw new Error('要重置的账号不存在');
if (!process.stdin.isTTY) throw new Error('请在交互终端执行');
process.stdout.write('密码（至少 12 位，不回显）：');
const password = await new Promise(resolve => {
  let value = '';
  process.stdin.setRawMode(true); process.stdin.resume(); process.stdin.setEncoding('utf8');
  function onData(chunk) {
    for (const char of chunk) {
      if (char === '\u0003') process.exit(1);
      if (char === '\r' || char === '\n') {
        process.stdin.off('data', onData); process.stdin.setRawMode(false); process.stdin.pause(); process.stdout.write('\n'); resolve(value); return;
      }
      if (char === '\u007f' || char === '\b') value = value.slice(0, -1);
      else value += char;
    }
  }
  process.stdin.on('data', onData);
});
if (password.length < 12 || password.length > 256) throw new Error('密码长度须为 12–256 位');
if (existing) {
  if (!resetUsername) throw new Error('账号已存在；如需修改密码，请执行 npm run user -- --reset 用户名');
  existing.passwordHash = hashPassword(password);
} else config.users.push({ username, role, passwordHash: hashPassword(password) });
writeFileSync(path, JSON.stringify(config, null, 2) + '\n', { mode: 0o600 });
console.log(`${resetUsername ? '密码已重置' : '账号已保存'}。服务运行时需重启才能加载。`);
