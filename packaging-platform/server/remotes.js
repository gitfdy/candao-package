import { fail } from './projects.js';

export function remoteClients(config, fetcher = fetch) {
  const jenkinsBase = config.jenkins.url.replace(/\/$/, '');
  const gitlabBase = config.gitlab.url.replace(/\/$/, '');
  const authorization = 'Basic ' + Buffer.from(`${config.jenkins.username}:${config.jenkins.token}`).toString('base64');
  const jobPath = job => '/job/' + job.split('/').map(encodeURIComponent).join('/job/');
  async function jenkins(path, options = {}, timeout = 30000) {
    const response = await fetcher(jenkinsBase + path, {
      ...options, redirect: 'manual', signal: AbortSignal.timeout(timeout),
      headers: { Authorization: authorization, ...options.headers }
    });
    if (!response.ok) fail(`Jenkins 请求失败（HTTP ${response.status}）`, 502);
    return response;
  }
  return {
    async branches(project) {
      const branches = [];
      let page = 1;
      do {
        const response = await fetcher(`${gitlabBase}/api/v4/projects/${encodeURIComponent(project.gitlab)}/repository/branches?per_page=100&page=${page}`, {
          headers: { 'PRIVATE-TOKEN': config.gitlab.token }, redirect: 'error', signal: AbortSignal.timeout(20000)
        });
        if (!response.ok) fail(`GitLab 分支读取失败（HTTP ${response.status}）`, 502);
        const items = await response.json();
        if (!Array.isArray(items)) fail('GitLab 返回无效分支列表', 502);
        branches.push(...items.map(item => item.name));
        page = Number(response.headers.get('x-next-page') || 0);
        if (page > 100) fail('分支数量超过当前平台分页上限', 502);
      } while (page);
      return branches.sort();
    },
    // Jenkins API tokens are exempt from CSRF crumbs; use tokens, never account passwords.
    async trigger(job, parameters) {
      const response = await jenkins(jobPath(job) + '/buildWithParameters', {
        method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(parameters)
      });
      const location = response.headers.get('location');
      const match = location && new URL(location, jenkinsBase).pathname.match(/\/queue\/item\/(\d+)\/?$/);
      if (!match) fail('Jenkins 未返回队列编号，需人工核对', 502);
      return Number(match[1]);
    },
    async queue(id) { return (await jenkins(`/queue/item/${id}/api/json`)).json(); },
    async build(job, number) {
      return (await jenkins(`${jobPath(job)}/${number}/api/json?tree=number,building,result,duration,timestamp,artifacts[fileName,relativePath]`)).json();
    },
    async log(job, number, start) {
      const response = await jenkins(`${jobPath(job)}/${number}/logText/progressiveText?start=${start}`);
      const reader = response.body.getReader();
      const chunks = []; let size = 0;
      while (size < 256000) {
        const chunk = await reader.read(); if (chunk.done) break;
        const part = chunk.value.subarray(0, 256000 - size); chunks.push(Buffer.from(part)); size += part.length;
      }
      await reader.cancel();
      const text = Buffer.concat(chunks).toString('utf8');
      return { text, next: start + size, more: response.headers.get('x-more-data') === 'true' || size >= 256000 };
    },
    async artifact(job, number, relativePath) {
      return jenkins(`${jobPath(job)}/${number}/artifact/${relativePath.split('/').map(encodeURIComponent).join('/')}`, {}, 15 * 60000);
    }
  };
}
