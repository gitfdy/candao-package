<script setup>
import { ref, computed, watch, onMounted, onUnmounted } from 'vue';
import Select from 'primevue/select';
import { api, statusLabel } from '../api.js';
import BuildLinks from './BuildLinks.vue';
import { copyText } from '../clipboard.js';
const props = defineProps(['project', 'selectedId']);
const emit = defineEmits(['select-build']);
const rows = ref([]), detail = ref(null), error = ref(''), log = ref(''), logOpen = ref(false);
const loading = ref(false), loaded = ref(false), logLoading = ref(false), refreshedAt = ref(null), copyMessage = ref('');
const query = ref(''), statusFilter = ref('all');
const statusOptions = [
  { label: '全部状态', value: 'all' }, { label: '排队中', value: 'QUEUED' },
  { label: '构建中', value: 'RUNNING' }, { label: '成功', value: 'SUCCESS' },
  { label: '失败', value: 'FAILURE' }, { label: '待人工核对', value: 'UNKNOWN' },
  { label: '提交被拒绝', value: 'REJECTED' }, { label: '已中止', value: 'ABORTED' },
  { label: '已取消', value: 'CANCELLED' }, { label: '不稳定', value: 'UNSTABLE' }, { label: '提交中', value: 'SUBMITTING' }
];
let offset = 0, timer, stopped = false, controller, requestVersion = 0;
const payload = row => JSON.parse(row.payload);
const filteredRows = computed(() => rows.value.filter(row =>
  (statusFilter.value === 'all' || row.status === statusFilter.value) &&
  `${row.id} ${row.actor} ${payload(row).name} ${payload(row).branch}`.toLowerCase().includes(query.value.toLowerCase().trim())
));
async function refresh() {
  if (loading.value || stopped) return;
  loading.value = true;
  const requestedId = props.selectedId;
  const version = ++requestVersion;
  controller = new AbortController();
  try {
    const data = await api(requestedId ? `/builds/${requestedId}` : `/builds?project=${props.project.id}`, { signal: AbortSignal.any([controller.signal, AbortSignal.timeout(45000)]) });
    if (stopped || version !== requestVersion) return;
    if (requestedId) detail.value = data; else rows.value = data;
    error.value = ''; loaded.value = true; refreshedAt.value = new Date();
  } catch (issue) { if (!stopped && version === requestVersion) error.value = issue.message; }
  finally { if (version === requestVersion) loading.value = false; }
}
watch(() => props.selectedId, () => {
  requestVersion++; controller?.abort(); loading.value = false; loaded.value = false;
  detail.value = null; log.value = ''; offset = 0; logOpen.value = false; error.value = ''; copyMessage.value = ''; refresh();
});
async function readLog() {
  if (logLoading.value) return;
  logLoading.value = true;
  const id = props.selectedId;
  try {
    const result = await api(`/builds/${id}/log?start=${offset}`);
    if (id !== props.selectedId || stopped) return;
    log.value = (log.value + result.text).slice(-500000); offset = result.next; logOpen.value = true;
  } catch (issue) { if (id === props.selectedId && !stopped) error.value = issue.message; }
  finally { logLoading.value = false; }
}
async function copyDetail() {
  try { await copyText(location.href); copyMessage.value = '详情地址已复制'; }
  catch (issue) { copyMessage.value = issue.message; }
}
onMounted(() => { refresh(); timer = setInterval(refresh, 5000); });
onUnmounted(() => { stopped = true; controller?.abort(); clearInterval(timer); });
</script>
<template>
  <template v-if="detail">
    <div class="row detail-back"><button @click="emit('select-build', null)">返回构建记录</button><button @click="copyDetail">复制详情地址</button><span v-if="copyMessage" role="status">{{ copyMessage }}</span></div>
    <div class="row spread detail-heading"><h1>构建 #{{ detail.id }}</h1><span class="pill" :data-status="detail.status">{{ detail.waitingForExecutor ? '等待执行器' : statusLabel(detail.status) }}</span></div>
    <p v-if="detail.error" class="error" role="alert">{{ detail.error }}</p>
    <div class="layout build-detail-layout">
      <section class="panel detail-panel">
        <div class="detail-section"><h2>执行状态</h2><p class="execution-state">{{ detail.waitingForExecutor ? '等待执行器' : statusLabel(detail.status) }}<template v-if="detail.number"> · Jenkins #{{ detail.number }}</template></p><div class="row detail-actions"><button :disabled="loading" @click="refresh">{{ loading ? '刷新中…' : '刷新状态' }}</button><button :disabled="!detail.number || logLoading" @click="readLog">{{ logLoading ? '读取日志…' : logOpen ? '加载后续日志' : '查看日志' }}</button></div><pre v-if="logOpen">{{ log || '暂无日志内容。' }}</pre></div>
        <div class="detail-section"><h2>下载链接</h2><BuildLinks v-if="detail.artifacts?.length" :key="`${detail.id}:${detail.artifacts.length}`" :row="detail" :build="detail" /><p v-else class="muted">{{ ['SUBMITTING', 'QUEUED', 'RUNNING'].includes(detail.status) ? '构建完成后将在这里显示下载链接。' : '本次构建暂无安装包。' }}</p></div>
      </section>
      <aside class="panel detail-panel"><h2>构建配置</h2><dl><dt>需求 / 分支</dt><dd>{{ payload(detail).name }}<br>{{ payload(detail).branch }}</dd><dt>环境 / 格式</dt><dd>{{ payload(detail).environment }} / {{ payload(detail).format }}</dd><dt>分发选项</dt><dd>{{ payload(detail).upload ? '上传 DUFS' : '不上传' }} · {{ payload(detail).notify ? '钉钉通知' : '不通知' }}</dd><dt>提交人</dt><dd>{{ detail.actor }}</dd><dt>提交时间</dt><dd>{{ new Date(detail.created).toLocaleString() }}</dd><dt>Jenkins 任务</dt><dd>{{ detail.job }}</dd></dl></aside>
    </div>
  </template>
  <template v-else-if="selectedId">
    <button @click="emit('select-build', null)">返回构建记录</button><h1>构建 #{{ selectedId }}</h1>
    <p v-if="loading && !error" class="panel" role="status">正在读取构建详情…</p>
  </template>
  <template v-else>
    <div class="row spread page-heading"><div><h1>构建记录</h1><p>最近 100 条 · 自动更新</p></div><button :disabled="loading" @click="refresh">{{ loading ? '刷新中…' : '刷新' }}</button></div>
    <div class="history-filters"><label>搜索记录<input v-model="query" type="search" placeholder="需求、分支、编号或提交人"></label><div class="control-field status-field"><label for="status-filter">状态</label><Select v-model="statusFilter" inputId="status-filter" :options="statusOptions" optionLabel="label" optionValue="value" class="full-width" /></div></div>
    <div class="panel record-list" :aria-busy="loading">
      <p v-if="!loaded && loading" class="loading-state" role="status">正在读取构建记录…</p>
      <article v-for="row in filteredRows" :key="row.id" class="record"><div><strong>#{{ row.id }} {{ payload(row).name }}</strong><p class="branch-code">{{ payload(row).branch }} · {{ payload(row).environment }} / {{ payload(row).format }}</p><small>{{ row.actor }} · {{ new Date(row.created).toLocaleString() }}</small><BuildLinks v-if="row.status === 'SUCCESS'" :row="row" /></div><div class="row"><span class="pill" :data-status="row.status">{{ row.waitingForExecutor ? '等待执行器' : statusLabel(row.status) }}</span><button @click="emit('select-build', row.id)">查看详情</button></div></article>
      <p v-if="loaded && !rows.length">暂无构建记录，请先发起打包。</p><p v-else-if="loaded && !filteredRows.length">没有匹配的构建记录，请调整搜索或状态筛选。</p>
      <div v-if="error" class="error" role="alert">{{ error }}<template v-if="loaded"> · 当前显示的是上次读取的数据。</template><button :disabled="loading" @click="refresh">重新读取</button></div>
    </div>
  </template>
  <p v-if="error && selectedId" class="error" role="alert">{{ error }} <button :disabled="loading" @click="refresh">重新读取</button></p>
  <p v-if="refreshedAt" class="muted refresh-time">最后更新：{{ refreshedAt.toLocaleTimeString() }}{{ error ? ' · 更新失败' : '' }}</p>
</template>
