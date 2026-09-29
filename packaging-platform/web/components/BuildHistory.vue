<script setup>
import { ref, onMounted, onUnmounted } from 'vue';
import { api, statusLabel } from '../api.js';
const props = defineProps(['project', 'selectedId']);
const rows = ref([]), detail = ref(null), error = ref(''), log = ref(''), logOpen = ref(false);
let selected = props.selectedId, offset = 0, timer, loading = false, stopped = false, logLoading = false;
const payload = row => JSON.parse(row.payload);
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
onMounted(() => { refresh(); timer = setInterval(refresh, 5000); });
onUnmounted(() => { stopped = true; clearInterval(timer); });
</script>
<template>
  <template v-if="detail"><button @click="back">返回构建记录</button><div class="row spread"><h1>构建 #{{ detail.id }}</h1><span class="pill">{{ statusLabel(detail.status) }}</span></div><p v-if="detail.error" class="error" role="alert">{{ detail.error }}</p><div class="layout"><section class="panel"><h2>执行状态</h2><p>{{ statusLabel(detail.status) }}<template v-if="detail.number"> · Jenkins #{{ detail.number }}</template></p><p class="muted">排队、编译与分发由 Jenkins 执行；此处显示实际返回状态。</p><div class="row"><button @click="refresh">刷新状态</button><button :disabled="!detail.number" @click="readLog">{{ logOpen ? '加载后续日志' : '查看日志' }}</button></div><pre v-if="logOpen">{{ log }}</pre><h2>安装包</h2><a v-for="(artifact, index) in detail.artifacts || []" :key="artifact.relativePath" class="artifact" :href="`/api/builds/${detail.id}/artifacts/${index}`">{{ artifact.fileName }}</a><p v-if="!detail.artifacts?.length" class="muted">暂无归档产物。</p></section><aside class="panel"><h2>构建配置</h2><dl><dt>需求 / 分支</dt><dd>{{ payload(detail).name }}<br>{{ payload(detail).branch }}</dd><dt>环境 / 格式</dt><dd>{{ payload(detail).environment }} / {{ payload(detail).format }}</dd><dt>分发选项</dt><dd>{{ payload(detail).upload ? '上传 DUFS' : '不上传' }} · {{ payload(detail).notify ? '钉钉通知' : '不通知' }}</dd><dt>提交人</dt><dd>{{ detail.actor }}</dd><dt>提交时间</dt><dd>{{ new Date(detail.created).toLocaleString() }}</dd><dt>Jenkins 任务</dt><dd>{{ detail.job }}</dd></dl></aside></div></template>
  <template v-else><div class="row spread"><div><h1>构建记录</h1><p>当前项目最近 100 次平台提交记录，自动刷新。</p></div><button @click="refresh">刷新</button></div><div class="panel"><article v-for="row in rows" :key="row.id" class="record"><div><strong>#{{ row.id }} {{ payload(row).name }}</strong><p>{{ payload(row).branch }} · {{ payload(row).environment }} / {{ payload(row).format }}</p><small>{{ row.actor }} · {{ new Date(row.created).toLocaleString() }}</small></div><div class="row"><span class="pill">{{ statusLabel(row.status) }}</span><button @click="open(row)">查看详情</button></div></article><p v-if="!rows.length">暂无记录，请到“发起打包”提交任务。此列表不导入 Jenkins 历史构建。</p></div></template>
  <p v-if="error" class="error" role="alert">{{ error }}</p>
</template>
