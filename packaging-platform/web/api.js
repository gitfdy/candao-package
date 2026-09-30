export async function api(path, options = {}) {
  const response = await fetch('/api' + path, {
    signal: AbortSignal.timeout(45000),
    ...options,
    headers: { 'Content-Type': 'application/json', 'X-Platform-Request': '1', ...options.headers },
    body: options.body === undefined ? undefined : JSON.stringify(options.body)
  });
  const data = await response.json();
  if (response.status === 401 && path !== '/login') window.dispatchEvent(new Event('platform-session-expired'));
  if (!response.ok) throw Object.assign(new Error(data.error || '请求失败'), { status: response.status });
  return data;
}
export const statusLabel = status => ({ SUBMITTING: '提交中', REJECTED: '提交被拒绝', UNKNOWN: '待人工核对', QUEUED: '排队中', RUNNING: '构建中', SUCCESS: '成功', FAILURE: '失败', ABORTED: '已中止', CANCELLED: '已取消', UNSTABLE: '不稳定' }[status] || status);
