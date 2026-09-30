<script setup>
import { ref, reactive, computed, watch } from 'vue';
import Select from 'primevue/select';
import { api } from '../api.js';
const props = defineProps(['project', 'branches', 'loading']);
const emit = defineEmits(['submitted']);
const form = reactive({ branch: '', environment: props.project.environments[0], format: props.project.formats[0], product: props.project.products?.[0], signingKey: '', versionCode: '', upload: false, notify: false });
const confirmation = ref(null), busy = ref(false), error = ref('');
const uncertain = ref(false);
const branch = computed(() => props.branches.find(item => item.branch === form.branch));
const branchOptions = computed(() => [...props.branches]
  .sort((a, b) => Number(Boolean(b.name)) - Number(Boolean(a.name)) || a.branch.localeCompare(b.branch))
  .map(item => ({ ...item, displayLabel: item.name && item.name !== item.branch ? `${item.name} · ${item.branch}` : item.branch })));
const canReview = computed(() => !props.loading && !!branch.value);
const currentStep = computed(() => busy.value ? 3 : confirmation.value ? 2 : 1);
watch(() => props.branches, branches => {
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
  try { emit('submitted', await api('/builds', { method: 'POST', body: confirmation.value })); }
  catch (issue) { error.value = issue.message; uncertain.value = !issue.status || issue.status >= 500; }
  finally { busy.value = false; }
}
</script>
<template>
  <div class="page-heading"><div><span class="eyebrow">{{ confirmation ? '第二步 · 最终核对' : '第一步 · 配置任务' }}</span><h1>{{ confirmation ? '确认打包' : '发起打包' }}</h1><p>{{ confirmation ? '请检查分支、环境和分发选项。提交后会立即触发 Jenkins。' : '选择需求分支和目标环境，确认后即可开始构建。' }}</p></div><div class="step-indicator" role="navigation" aria-label="打包步骤"><button type="button" :class="{ active: currentStep === 1, completed: currentStep > 1 }" :aria-current="currentStep === 1 ? 'step' : undefined" :disabled="busy" @click="confirmation = null">1 配置</button><button type="button" :class="{ active: currentStep === 2, completed: currentStep > 2 }" :aria-current="currentStep === 2 ? 'step' : undefined" :disabled="busy || !canReview" @click="review">2 确认</button><button type="button" :class="{ active: currentStep === 3 }" :aria-current="currentStep === 3 ? 'step' : undefined" disabled>3 构建</button></div></div>
  <template v-if="confirmation">
    <div class="panel review-panel"><div class="review-banner"><span class="review-icon">✓</span><div><strong>即将创建真实构建</strong><p>本次打包不会自动上传或通知，除非你在上一步明确开启。</p></div></div><dl class="review-grid"><div><dt>项目</dt><dd>{{ project.name }}</dd></div><div><dt>需求 / 分支</dt><dd>{{ confirmation.name }}<span class="code-line">{{ confirmation.branch }}</span></dd></div><div><dt>环境 / 格式</dt><dd>{{ confirmation.environment }} · {{ confirmation.format.toUpperCase() }}</dd></div><div v-if="project.products"><dt>产品</dt><dd>{{ confirmation.product }}</dd></div><div v-if="project.signing"><dt>签名 / 版本号</dt><dd>{{ confirmation.signingKey || '内部测试签名' }} · {{ confirmation.versionCode || '沿用源码' }}</dd></div><div><dt>分发</dt><dd>{{ confirmation.upload ? '上传 DUFS' : '不上传' }} · {{ confirmation.notify ? '发送钉钉通知' : '不通知' }}</dd></div></dl><div class="footer"><span class="muted">提交后可在“构建记录”查看进度与产物。</span><button class="primary" :disabled="busy" @click="submit">{{ busy ? '正在提交，请勿重复操作…' : '确认提交打包' }}</button></div></div>
  </template>
  <template v-else>
    <form class="build-layout" @submit.prevent="review">
      <div class="panel build-fields">
      <div class="section-heading"><span class="section-number">01</span><div><h2>选择需求</h2><p>打开下拉框可浏览全部分支，也可以输入名称或分支名筛选。</p></div></div><label class="field-label" for="branch-select">需求 / 分支</label><Select v-model="form.branch" inputId="branch-select" :options="branchOptions" optionLabel="displayLabel" optionValue="branch" filter :filterFields="['name', 'branch', 'description']" :loading="loading" :disabled="loading || !branches.length" placeholder="选择一个需求分支" class="full-width"><template #option="slotProps"><span class="branch-choice"><strong>{{ slotProps.option.name || slotProps.option.branch }}</strong><code>{{ slotProps.option.branch }}</code><small v-if="slotProps.option.description">{{ slotProps.option.description }}</small></span></template></Select><p class="field-hint">共 {{ branches.length }} 个可用分支，列表可滚动浏览。</p>
      <p v-if="loading" role="status">正在读取远端分支…</p><p v-else-if="!branches.length">暂无可用分支，请确认 GitLab 连接或刷新列表。</p>
      <div v-if="branch" class="selected-branch"><span>已选择</span><strong>{{ branch.name || branch.branch }}</strong><p>{{ branch.description || '暂无变更备注' }}</p></div>
      <div class="section-heading section-divider"><span class="section-number">02</span><div><h2>打包配置</h2><p>环境与分支独立选择。</p></div></div><div class="fields"><div class="control-field"><label for="environment-select">目标环境</label><Select v-model="form.environment" inputId="environment-select" :options="project.environments" class="full-width" /></div><div v-if="project.formats.length > 1" class="control-field"><label for="format-select">包格式</label><Select v-model="form.format" inputId="format-select" :options="project.formats" class="full-width" /></div><div v-if="project.products" class="control-field"><label for="product-select">产品</label><Select v-model="form.product" inputId="product-select" :options="project.products" class="full-width" /></div></div>
      <template v-if="project.signing"><div class="fields"><label>签名凭据<select v-model="form.signingKey" :required="project.id === 'tappo-phone' && form.format === 'aab'"><option value="">内部测试签名</option><option v-for="key in project.signingKeys" :key="key.id" :value="key.id">{{ key.label }}</option></select></label><label>版本号（可选）<input v-model="form.versionCode" inputmode="numeric" pattern="[1-9][0-9]*" placeholder="留空沿用源码 versionCode"></label></div><p class="muted">Tappo Phone AAB 必须选择原 Google Play 上传密钥。APK 内部测试签名不能覆盖不同签名的应用。</p></template>
      <details class="distribution-options"><summary><strong>分发选项</strong><span>{{ [form.upload && '上传 DUFS', form.notify && '钉钉通知'].filter(Boolean).join(' · ') || '默认关闭，按需开启' }}</span></summary><div class="toggle-grid"><label class="check"><input v-model="form.upload" type="checkbox"><span><strong>上传 DUFS</strong><small>将产物上传到文件服务</small></span></label><label class="check"><input v-model="form.notify" type="checkbox"><span><strong>钉钉通知</strong><small>构建结束后发送通知</small></span></label></div></details>
      </div>
      <aside class="panel build-summary" aria-label="当前打包任务摘要"><span class="summary-kicker">当前任务</span><h2>核对你的打包选择</h2><p class="summary-intro">这里会随配置实时更新。下一步还可以最终核对。</p><dl><div><dt>项目</dt><dd>{{ project.name }}</dd></div><div><dt>需求分支</dt><dd v-if="branch"><strong>{{ branch.name || branch.branch }}</strong><code>{{ branch.branch }}</code></dd><dd v-else>请先选择分支</dd></div><div><dt>目标环境</dt><dd>{{ form.environment }}</dd></div><div><dt>包格式</dt><dd>{{ form.format.toUpperCase() }}</dd></div><div v-if="project.products"><dt>产品</dt><dd>{{ form.product }}</dd></div><div><dt>分发</dt><dd>{{ form.upload ? '上传' : '不上传' }} · {{ form.notify ? '通知' : '不通知' }}</dd></div></dl><button class="primary summary-action" :disabled="!canReview">核对配置</button><p class="summary-footnote">此步骤不会提交构建。</p></aside>
    </form>
  </template>
  <p v-if="error" class="error" role="alert">{{ error }}<template v-if="uncertain">。提交响应不明时，请先查看构建记录；再次点击确认将复用同一请求编号。</template></p>
</template>
