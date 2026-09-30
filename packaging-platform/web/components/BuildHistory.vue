<script setup>
import { ref, computed, watch, onMounted, onUnmounted } from 'vue';
import Select from 'primevue/select';
import { api, statusLabel } from '../api.js';
import BuildLinks from './BuildLinks.vue';
const props = defineProps(['project', 'selectedId']);
const rows = ref([]), detail = ref(null), error = ref(''), log = ref(''), logOpen = ref(false);
const query = ref(''), statusFilter = ref('all');
const statusOptions = [
  { label: '全部状态', value: 'all' }, { label: '排队中', value: 'QUEUED' },
  { label: '构建中', value: 'RUNNING' }, { label: '成功', value: 'SUCCESS' },
  { label: '失败', value: 'FAILURE' }, { label: '待人工核对', value: 'UNKNOWN' },
  { label: '提交被拒绝', value: 'REJECTED' }
];
const downloadProgress = ref(''), downloading = ref(false);
const dufsLinks = ref([]), linksError = ref(''), linksLoading = ref(false);
const packageArtifacts = computed(() => (detail.value?.artifacts || [])
  .map((artifact, index) => ({ ...artifact, index }))
  .filter(artifact => artifact.fileName !== 'dufs-links.txt'));
const linksArtifact = computed(() => (detail.value?.artifacts || [])
  .findIndex(artifact => artifact.fileName === 'dufs-links.txt'));
let linksRequest = 0;
async function loadDufsLinks() {
  const request = ++linksRequest;
  dufsLinks.value = []; linksError.value = ''; linksLoading.value = false;
  if (!detail.value || linksArtifact.value < 0) return;
  linksLoading.value = true;
  try {
    const response = await fetch(`/api/builds/${detail.value.id}/artifacts/${linksArtifact.value}`, { cache: 'no-store', signal: AbortSignal.timeout(120000) });
    if (!response.ok) throw new Error(`读取 DUFS 链接失败（HTTP ${response.status}）`);
    const content = await response.text();
    if (request !== linksRequest) return;
    dufsLinks.value = content.split(/\r?\n/).map(line => line.trim()).filter(line => /^https?:\/\//i.test(line));
  } catch (issue) { if (request === linksRequest) linksError.value = issue.name === 'TimeoutError' ? '读取 DUFS 链接超时，请重试。' : issue.message; }
  finally { if (request === linksRequest) linksLoading.value = false; }
}
watch(() => `${detail.value?.id || ''}:${linksArtifact.value}`, loadDufsLinks);
let selected = props.selectedId, offset = 0, timer, loading = false, stopped = false, logLoading = false;
const payload = row => JSON.parse(row.payload);
const filteredRows = computed(() => rows.value.filter(row =>
  (statusFilter.value === 'all' || row.status === statusFilter.value) &&
  `${row.id} ${row.actor} ${payload(row).name} ${payload(row).branch}`.toLowerCase().includes(query.value.toLowerCase().trim())
));
async function refresh() {
  if (loading || stopped) return;
  loading = true;
  const requestedId = selected;
  try {
    const data = requestedId ? await api(`/builds/${requestedId}`) : await api(`/builds?project=${props.project.id}`);
    if (stopped || requestedId !== selected) return;
    if (requestedId) detail.value = data; else rows.value = data;
    error.value = '';
  } catch (issue) { if (!stopped) error.value = issue.message; }
  finally { loading = false; }
}
async function open(row) {
  selected = row.id; detail.value = row; log.value = ''; offset = 0; logOpen.value = false; await refresh();
}
async function readLog() {
  if (logLoading) return;
  logLoading = true;
  const id = selected;
  try {
    const result = await api(`/builds/${id}/log?start=${offset}`);
    if (id !== selected || stopped) return;
    log.value = (log.value + result.text).slice(-500000); offset = result.next; logOpen.value = true;
  } catch (issue) { error.value = issue.message; }
  finally { logLoading = false; }
}
function back() { selected = null; detail.value = null; refresh(); }
async function downloadArtifact(artifact, index) {
  if (downloading.value) return;
  downloading.value = true; downloadProgress.value = '准备下载…'; error.value = '';
  const url = `/api/builds/${detail.value.id}/artifacts/${index}`;
  const chunkSize = 4 * 1024 * 1024;
  const parts = [];
  let received = 0, total = 0;
  try {
    do {
      let bytes;
      for (let attempt = 0; attempt < 8; attempt++) {
        try {
          const end = total ? Math.min(received + chunkSize - 1, total - 1) : received + chunkSize - 1;
          const response = await fetch(url, { headers: { Range: `bytes=${received}-${end}` }, cache: 'no-store' });
          if (response.status !== 206) throw new Error(`分段下载失败（HTTP ${response.status}）`);
          const match = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(response.headers.get('content-range') || '');
          if (!match || Number(match[1]) !== received || (total && Number(match[3]) !== total)) throw new Error('下载范围响应无效');
          total = Number(match[3]);
          bytes = await response.arrayBuffer();
          if (bytes.byteLength !== Number(match[2]) - received + 1) throw new Error('下载分段不完整');
          break;
        } catch (issue) {
          if (attempt === 7 || /HTTP 4\d\d|下载范围响应无效/.test(issue.message)) throw issue;
          downloadProgress.value = `连接中断，正在重试第 ${Math.floor(received / chunkSize) + 1} 段…`;
          await new Promise(resolve => setTimeout(resolve, Math.min(1000 * 2 ** attempt, 30000)));
        }
      }
      parts.push(bytes); received += bytes.byteLength;
      downloadProgress.value = `已下载 ${Math.round(received / total * 100)}%`;
    } while (received < total);
    const blobUrl = URL.createObjectURL(new Blob(parts, { type: 'application/octet-stream' }));
    const link = document.createElement('a'); link.href = blobUrl; link.download = artifact.fileName;
    document.body.append(link); link.click(); link.remove();
    setTimeout(() => URL.revokeObjectURL(blobUrl), 60000);
    downloadProgress.value = '下载已准备完成';
  } catch (issue) { error.value = issue.message; downloadProgress.value = ''; }
  finally { downloading.value = false; }
}
onMounted(() => { refresh(); timer = setInterval(refresh, 5000); });
onUnmounted(() => { stopped = true; clearInterval(timer); });
</script>
<template>
  <template v-if="detail">
    <button class="detail-back" @click="back">返回构建记录</button>
    <div class="row spread detail-heading"><h1>构建 #{{ detail.id }}</h1><span class="pill" :data-status="detail.status">{{ detail.waitingForExecutor ? '等待执行器' : statusLabel(detail.status) }}</span></div>
    <p v-if="detail.error" class="error" role="alert">{{ detail.error }}</p>
    <div class="layout build-detail-layout">
      <section class="panel detail-panel">
        <div class="detail-section"><h2>执行状态</h2><p class="execution-state">{{ detail.waitingForExecutor ? '等待执行器' : statusLabel(detail.status) }}<template v-if="detail.number"> · Jenkins #{{ detail.number }}</template></p><p class="muted">排队、编译与分发由 Jenkins 执行；此处显示实际返回状态。</p><div class="row detail-actions"><button @click="refresh">刷新状态</button><button :disabled="!detail.number" @click="readLog">{{ logOpen ? '加载后续日志' : '查看日志' }}</button></div><pre v-if="logOpen">{{ log }}</pre></div>
        <div class="detail-section"><h2>安装包</h2><div class="artifact-list"><button v-for="artifact in packageArtifacts" :key="artifact.relativePath" class="artifact" :disabled="downloading" @click="downloadArtifact(artifact, artifact.index)">下载 {{ artifact.fileName }}</button></div><p v-if="downloadProgress" role="status">{{ downloadProgress }}</p><p v-if="!packageArtifacts.length" class="muted">暂无安装包。</p></div>
        <div v-if="payload(detail).upload" class="detail-section"><h2>DUFS 链接</h2><p v-if="linksLoading" class="muted">正在读取链接…</p><template v-else-if="linksError"><p class="error" role="alert">{{ linksError }}</p><button @click="loadDufsLinks">重试读取链接</button></template><ul v-else-if="dufsLinks.length" class="dufs-links"><li v-for="link in dufsLinks" :key="link"><a :href="link" target="_blank" rel="noopener noreferrer">{{ link }}</a></li></ul><p v-else class="muted">{{ linksArtifact < 0 ? '构建完成后将在这里显示链接。' : '链接文件中暂无有效地址。' }}</p></div>
      </section>
      <aside class="panel detail-panel"><h2>构建配置</h2><dl><dt>需求 / 分支</dt><dd>{{ payload(detail).name }}<br>{{ payload(detail).branch }}</dd><dt>环境 / 格式</dt><dd>{{ payload(detail).environment }} / {{ payload(detail).format }}</dd><dt>分发选项</dt><dd>{{ payload(detail).upload ? '上传 DUFS' : '不上传' }} · {{ payload(detail).notify ? '钉钉通知' : '不通知' }}</dd><dt>提交人</dt><dd>{{ detail.actor }}</dd><dt>提交时间</dt><dd>{{ new Date(detail.created).toLocaleString() }}</dd><dt>Jenkins 任务</dt><dd>{{ detail.job }}</dd></dl></aside>
    </div>
  </template>
  <template v-else><div class="row spread page-heading"><div><h1>构建记录</h1><p>当前项目最近 100 次提交，状态每 5 秒更新。</p></div><button @click="refresh">刷新</button></div><div class="history-filters"><label>搜索记录<input v-model="query" type="search" placeholder="需求、分支、编号或提交人"></label><div class="control-field status-field"><label for="status-filter">状态</label><Select v-model="statusFilter" inputId="status-filter" :options="statusOptions" optionLabel="label" optionValue="value" class="full-width" /></div></div><div class="panel record-list"><article v-for="row in filteredRows" :key="row.id" class="record"><div><strong>#{{ row.id }} {{ payload(row).name }}</strong><p class="branch-code">{{ payload(row).branch }} · {{ payload(row).environment }} / {{ payload(row).format }}</p><small>{{ row.actor }} · {{ new Date(row.created).toLocaleString() }}</small><BuildLinks v-if="row.status === 'SUCCESS'" :row="row" /></div><div class="row"><span class="pill" :data-status="row.status">{{ row.waitingForExecutor ? '等待执行器' : statusLabel(row.status) }}</span><button @click="open(row)">查看详情</button></div></article><p v-if="!rows.length">暂无记录，请到“发起打包”提交任务。此列表不导入 Jenkins 历史构建。</p><p v-else-if="!filteredRows.length">没有匹配的构建记录，请调整搜索或状态筛选。</p></div></template>
  <p v-if="error" class="error" role="alert">{{ error }}</p>
</template>
