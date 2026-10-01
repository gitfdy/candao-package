<script setup>
import { ref, reactive, computed, watch, onMounted, onBeforeUnmount } from 'vue';
import Select from 'primevue/select';
import { api } from '../api.js';
const props = defineProps(['project', 'branches', 'loading', 'userKey']);
const emit = defineEmits(['submitted']);
const form = reactive({ branch: '', environment: props.project.environments[0], format: props.project.formats[0], product: props.project.products?.[0], signingKey: '', versionCode: '', upload: false, notify: false });
const confirmation = ref(null), busy = ref(false), error = ref('');
const uncertain = ref(false);
const draftKey = `build-draft:${props.userKey || 'guest'}:${props.project.id}`;
try {
  const draft = JSON.parse(sessionStorage.getItem(draftKey) || 'null');
  if (draft && typeof draft === 'object') {
    for (const key of Object.keys(form)) if (typeof draft[key] === typeof form[key]) form[key] = draft[key];
    if (!props.project.environments.includes(form.environment)) form.environment = props.project.environments[0];
    if (!props.project.formats.includes(form.format)) form.format = props.project.formats[0];
    if (props.project.products && !props.project.products.includes(form.product)) form.product = props.project.products[0];
    if (form.signingKey && !props.project.signingKeys?.some(key => key.id === form.signingKey)) form.signingKey = '';
  }
} catch { /* Storage can be unavailable in restricted browsers. */ }
watch(form, () => { try { sessionStorage.setItem(draftKey, JSON.stringify(form)); } catch {} }, { deep: true });
function canLeave() { return !busy.value; }
function beforeUnload(event) { if (busy.value) { event.preventDefault(); event.returnValue = ''; } }
onMounted(() => window.addEventListener('beforeunload', beforeUnload));
onBeforeUnmount(() => window.removeEventListener('beforeunload', beforeUnload));
defineExpose({ canLeave });
const branch = computed(() => props.branches.find(item => item.branch === form.branch));
const branchOptions = computed(() => [...props.branches]
  .sort((a, b) => Number(Boolean(b.name)) - Number(Boolean(a.name)) || a.branch.localeCompare(b.branch))
  .map(item => ({ ...item, displayLabel: item.name && item.name !== item.branch ? `${item.name} · ${item.branch}` : item.branch })));
const canReview = computed(() => !props.loading && !!branch.value);
watch(() => [props.branches, props.loading], ([branches, loading]) => {
  if (loading || !branches.length) return;
  if (!branches.some(item => item.branch === form.branch)) form.branch = branches.find(item => item.branch === 'devlop_qc')?.branch || branches[0]?.branch || '';
}, { immediate: true });
function review() {
  if (!canReview.value || confirmation.value || busy.value) return;
  error.value = '';
  // Retain the same request ID when retrying an uncertain HTTP response.
  const requestId = Array.from(crypto.getRandomValues(new Uint8Array(16)), byte => byte.toString(16).padStart(2, '0')).join('');
  confirmation.value = { ...form, project: props.project.id, requestId, name: branch.value.name || form.branch };
}
async function submit() {
  busy.value = true; error.value = ''; uncertain.value = false;
  try {
    const build = await api('/builds', { method: 'POST', body: confirmation.value });
    try { sessionStorage.removeItem(draftKey); } catch {}
    emit('submitted', build);
  }
  catch (issue) { error.value = issue.message; uncertain.value = !issue.status || issue.status >= 500; }
  finally { busy.value = false; }
}
</script>
<template>
  <div class="page-heading"><div><h1>{{ confirmation ? '确认打包' : '发起打包' }}</h1><p>{{ confirmation ? '核对本次配置后提交。' : '选择需求与环境，核对后提交构建。' }}</p></div></div>
  <template v-if="confirmation">
    <div class="panel review-panel"><dl class="review-grid"><div><dt>项目</dt><dd>{{ project.name }}</dd></div><div><dt>需求 / 分支</dt><dd>{{ confirmation.name }}<span class="code-line">{{ confirmation.branch }}</span></dd></div><div><dt>环境 / 格式</dt><dd>{{ confirmation.environment }} · {{ confirmation.format.toUpperCase() }}</dd></div><div v-if="project.products"><dt>产品</dt><dd>{{ confirmation.product }}</dd></div><div v-if="project.signing"><dt>签名 / 版本号</dt><dd>{{ confirmation.signingKey || '内部测试签名' }} · {{ confirmation.versionCode || '沿用源码' }}</dd></div><div><dt>分发</dt><dd>{{ confirmation.upload ? '上传 DUFS' : '不上传' }} · {{ confirmation.notify ? '发送钉钉通知' : '不通知' }}</dd></div></dl><div class="footer"><button type="button" :disabled="busy" @click="confirmation = null">返回修改</button><button class="primary" :disabled="busy" @click="submit">{{ busy ? '正在提交…' : '确认提交打包' }}</button></div></div>
  </template>
  <template v-else>
    <form class="build-layout" @submit.prevent="review">
      <div class="panel build-fields">
      <div class="section-heading"><span class="section-number">01</span><div><h2>选择需求</h2><p>可按需求名或分支名搜索。</p></div></div><label class="field-label" for="branch-select">需求 / 分支</label><Select v-model="form.branch" inputId="branch-select" :options="branchOptions" optionLabel="displayLabel" optionValue="branch" filter :filterFields="['name', 'branch', 'description']" :loading="loading" :disabled="loading || !branches.length" placeholder="选择一个需求分支" class="full-width"><template #option="slotProps"><span class="branch-choice"><strong>{{ slotProps.option.name || slotProps.option.branch }}</strong><code>{{ slotProps.option.branch }}</code><small v-if="slotProps.option.description">{{ slotProps.option.description }}</small></span></template></Select>
      <p v-if="loading" role="status">正在读取远端分支…</p><p v-else-if="!branches.length">暂无可用分支，请确认 GitLab 连接或刷新列表。</p>
      <div v-if="branch?.description" class="selected-branch"><p>{{ branch.description }}</p></div>
      <div class="section-heading section-divider"><span class="section-number">02</span><div><h2>打包配置</h2></div></div><div class="fields"><div class="control-field"><label for="environment-select">目标环境</label><Select v-model="form.environment" inputId="environment-select" :options="project.environments" class="full-width" /></div><div v-if="project.formats.length > 1" class="control-field"><label for="format-select">包格式</label><Select v-model="form.format" inputId="format-select" :options="project.formats" class="full-width" /></div><div v-if="project.products" class="control-field"><label for="product-select">产品</label><Select v-model="form.product" inputId="product-select" :options="project.products" class="full-width" /></div></div>
      <template v-if="project.signing"><div class="fields"><label>签名凭据<select v-model="form.signingKey" :required="project.id === 'tappo-phone' && form.format === 'aab'"><option value="">内部测试签名</option><option v-for="key in project.signingKeys" :key="key.id" :value="key.id">{{ key.label }}</option></select></label><label>版本号（可选）<input v-model="form.versionCode" inputmode="numeric" pattern="[1-9][0-9]*" placeholder="留空沿用源码 versionCode"></label></div><p class="muted">Tappo Phone AAB 必须选择原 Google Play 上传密钥。APK 内部测试签名不能覆盖不同签名的应用。</p></template>
      <section class="distribution-options" aria-labelledby="distribution-heading"><h2 id="distribution-heading">分发选项</h2><div class="toggle-grid"><label class="check"><input v-model="form.upload" type="checkbox"><span><strong>上传 DUFS</strong></span></label><label class="check"><input v-model="form.notify" type="checkbox"><span><strong>钉钉通知</strong><small>构建结束后发送通知</small></span></label></div></section>
      <div class="build-form-actions"><button class="primary" :disabled="!canReview">下一步：核对配置</button></div>
      </div>
    </form>
  </template>
  <p v-if="error" class="error" role="alert">{{ error }}<template v-if="uncertain">。提交响应不明时，请先查看构建记录；再次点击确认将复用同一请求编号。</template></p>
</template>
