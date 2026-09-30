import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { projects } from '../server/projects.js';

const path = fileURLToPath(new URL('../config.local.json', import.meta.url));
const config = JSON.parse(readFileSync(path, 'utf8'));
const { url, username, token, jobs = {} } = config.jenkins || {};
if (!url || !username || !token) throw new Error('请先配置 jenkins.url、username 和 API Token');
const base = new URL(url);
if (!['http:', 'https:'].includes(base.protocol) || base.username || base.password || base.search || base.hash) throw new Error('Jenkins 地址无效');
const headers = { Authorization: 'Basic ' + Buffer.from(`${username}:${token}`).toString('base64') };
async function read(path) {
  const response = await fetch(url.replace(/\/$/, '') + path, { headers, redirect: 'error', signal: AbortSignal.timeout(20000) });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}
try {
  const identity = await read('/whoAmI/api/json');
  if (!identity.authenticated || identity.anonymous) throw new Error('服务账号未通过身份验证');
  const post = await fetch(url.replace(/\/$/, '') + '/whoAmI/api/json', { method: 'POST', headers, redirect: 'error', signal: AbortSignal.timeout(20000) });
  if (!post.ok) {
    const text = await post.text();
    if (/No valid crumb|invalid crumb/i.test(text)) throw new Error('CSRF 校验失败：请将 jenkins.token 配置为 Jenkins API Token，而非登录密码');
    throw new Error(`POST 认证检查失败（HTTP ${post.status}）`);
  }
  console.log('Jenkins 服务账号认证成功');
} catch (error) {
  console.error(`Jenkins 认证检查失败：${error.message}`);
  process.exit(1);
}
for (const project of projects) {
  const job = jobs[project.id] || project.job;
  const path = '/job/' + job.split('/').map(encodeURIComponent).join('/job/');
  try {
    const details = await read(path + '/api/json?tree=buildable,property[parameterDefinitions[name]]');
    const names = (details.property || []).flatMap(item => (item.parameterDefinitions || []).map(parameter => parameter.name));
    const expected = ['BRANCH', project.environmentParameter || 'ENVIRONMENT', 'UPLOAD_DUFS', 'SEND_DINGTALK'];
    if (project.repository) expected.push('REPOSITORY_URL');
    if (project.incident) expected.push('ENABLE_INCIDENT_UPLOAD');
    if (project.products) expected.push('PRODUCT');
    if (project.signing) expected.push('PACKAGE_FORMAT', 'SIGNING_KEY', 'VERSION_CODE');
    const missing = expected.filter(name => !names.includes(name));
    if (!details.buildable || missing.length) {
      console.error(`${project.name} (${job})：${!details.buildable ? '任务不可构建；' : ''}${missing.length ? '缺少参数 ' + missing.join(', ') : ''}`);
      process.exitCode = 1;
    } else console.log(`${project.name} (${job})：任务可读取，构建参数匹配`);
  } catch (error) {
    console.error(`${project.name} (${job})：检查失败 ${error.message}`);
    process.exitCode = 1;
  }
}
console.log('此检查只读取 Jenkins；Build 和产物权限仍需在 Jenkins 中授予。没有触发构建。');
