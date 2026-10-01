import { reactive } from 'vue';

export const downloads = reactive([]);
const controllers = new Map();
export const downloadKey = (buildId, index) => `${buildId}:${index}`;
export function startDownload(buildId, artifact, index) {
  const key = downloadKey(buildId, index);
  let task = downloads.find(item => item.key === key);
  if (task?.status === 'running') return;
  if (!task) { downloads.push({ key, buildId, artifact, index, name: artifact.fileName }); task = downloads.find(item => item.key === key); }
  Object.assign(task, { status: 'running', progress: '准备下载…', percent: 0, error: '' });
  const controller = new AbortController();
  controllers.set(key, controller);
  return downloadBuildArtifact(buildId, artifact, index, (progress, percent) => {
    task.progress = progress;
    if (percent !== undefined) task.percent = percent;
  }, controller.signal).then(() => {
    task.status = 'complete'; task.progress = '已交给浏览器保存';
  }).catch(issue => {
    task.status = controller.signal.aborted ? 'cancelled' : 'failed';
    task.error = controller.signal.aborted ? '' : issue.message;
    task.progress = controller.signal.aborted ? '已取消下载' : '下载失败';
  }).finally(() => controllers.delete(key));
}
export function cancelDownload(key) { controllers.get(key)?.abort(); }
export function dismissDownload(key) {
  const index = downloads.findIndex(item => item.key === key && item.status !== 'running');
  if (index >= 0) downloads.splice(index, 1);
}
function waitForRetry(ms, signal) {
  return new Promise((resolve, reject) => {
    signal?.throwIfAborted();
    const done = () => { signal?.removeEventListener('abort', abort); resolve(); };
    const timer = setTimeout(done, ms);
    const abort = () => { clearTimeout(timer); reject(signal.reason); };
    signal?.addEventListener('abort', abort, { once: true });
  });
}

export async function downloadBuildArtifact(buildId, artifact, index, onProgress = () => {}, signal) {
  const url = `/api/builds/${buildId}/artifacts/${index}`;
  const chunkSize = 4 * 1024 * 1024;
  const parts = [];
  let received = 0, total = 0;
  onProgress('准备下载…');
  do {
    signal?.throwIfAborted();
    let bytes;
    for (let attempt = 0; attempt < 8; attempt++) {
      try {
        const end = total ? Math.min(received + chunkSize - 1, total - 1) : received + chunkSize - 1;
        const timeout = AbortSignal.timeout(45000);
        const response = await fetch(url, { signal: signal ? AbortSignal.any([signal, timeout]) : timeout, headers: { Range: `bytes=${received}-${end}` }, cache: 'no-store' });
        if (response.status !== 206) throw new Error(`分段下载失败（HTTP ${response.status}）`);
        const match = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(response.headers.get('content-range') || '');
        if (!match || Number(match[1]) !== received || (total && Number(match[3]) !== total)) throw new Error('下载范围响应无效');
        total = Number(match[3]);
        bytes = await response.arrayBuffer();
        if (bytes.byteLength !== Number(match[2]) - received + 1) throw new Error('下载分段不完整');
        break;
      } catch (issue) {
        signal?.throwIfAborted();
        if (attempt === 7 || /HTTP 4\d\d|下载范围响应无效/.test(issue.message)) throw issue;
        onProgress(`连接中断，正在重试第 ${Math.floor(received / chunkSize) + 1} 段…`);
        await waitForRetry(Math.min(1000 * 2 ** attempt, 30000), signal);
      }
    }
    parts.push(bytes); received += bytes.byteLength;
    onProgress(`已下载 ${Math.round(received / total * 100)}%`, Math.round(received / total * 100));
  } while (received < total);
  signal?.throwIfAborted();
  const blobUrl = URL.createObjectURL(new Blob(parts, { type: 'application/octet-stream' }));
  const link = document.createElement('a'); link.href = blobUrl; link.download = artifact.fileName;
  document.body.append(link); link.click(); link.remove();
  setTimeout(() => URL.revokeObjectURL(blobUrl), 60000);
  onProgress('下载已准备完成');
}
