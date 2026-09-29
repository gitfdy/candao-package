<script setup>
import { ref, reactive, computed, watch } from 'vue';
import { api } from '../api.js';
const props = defineProps(['project', 'branches', 'loading']);
const emit = defineEmits(['submitted']);
const form = reactive({ branch: '', environment: props.project.environments[0], format: props.project.formats[0], product: props.project.products?.[0], signingKey: '', versionCode: '', upload: false, notify: false, incident: false });
const confirmation = ref(null), busy = ref(false), error = ref('');
const branch = computed(() => props.branches.find(item => item.branch === form.branch));
watch(() => props.branches, branches => {
  if (!branches.some(item => item.branch === form.branch)) form.branch = branches.find(item => item.branch === 'devlop_qc')?.branch || branches[0]?.branch || '';
}, { immediate: true });
function review() {
  if (!branch.value) return;
  error.value = '';
  // Retain the same request ID when retrying an uncertain HTTP response.
  const requestId = Array.from(crypto.getRandomValues(new Uint8Array(16)), byte => byte.toString(16).padStart(2, '0')).join('');
  confirmation.value = { ...form, project: props.project.id, requestId, name: branch.value.name || form.branch };
}
async function submit() {
  busy.value = true; error.value = '';
  try { emit('submitted', await api('/builds', { method: 'POST', body: confirmation.value })); }
  catch (issue) { error.value = issue.message; }
  finally { busy.value = false; }
}
</script>
<template>
  <template v-if="confirmation">
    <button :disabled="busy" @click="confirmation = null">返回修改</button><h1>确认打包</h1>
    <div class="panel"><dl><dt>项目</dt><dd>{{ project.name }}</dd><dt>需求 / 分支</dt><dd>{{ confirmation.name }} / {{ confirmation.branch }}</dd><dt>环境 / 格式</dt><dd>{{ confirmation.environment }} / {{ confirmation.format.toUpperCase() }}</dd><template v-if="project.products"><dt>产品</dt><dd>{{ confirmation.product }}</dd></template><template v-if="project.signing"><dt>签名 / 版本号</dt><dd>{{ confirmation.signingKey || '内部测试签名，不可上架' }} / {{ confirmation.versionCode || '沿用源码' }}</dd></template><dt>上传 / 通知</dt><dd>{{ confirmation.upload ? '上传 DUFS' : '不上传' }} · {{ confirmation.notify ? '发送钉钉通知' : '不通知' }}</dd><template v-if="project.incident"><dt>故障上报</dt><dd>{{ confirmation.incident ? '开启' : '关闭' }}</dd></template></dl><div class="footer"><span class="muted">确认后会真实触发 Jenkins；所选上传和通知将随流水线执行。</span><button class="primary" :disabled="busy" @click="submit">{{ busy ? '正在提交，请勿重复操作…' : '确认提交打包' }}</button></div></div>
  </template>
  <template v-else>
    <h1>发起打包</h1><p>按需求找到分支，环境独立选择。</p>
    <form class="panel" @submit.prevent="review">
      <h2>选择需求</h2><label>需求 / 分支<select v-model="form.branch" :disabled="loading" required><option v-for="item in branches" :key="item.branch" :value="item.branch">{{ item.name || '未填写说明' }} · {{ item.branch }}</option></select></label>
      <p v-if="loading" role="status">正在读取远端分支…</p><p v-else-if="!branches.length">暂无可用分支，请确认 GitLab 连接或刷新列表。</p>
      <div v-if="branch" class="note"><strong>{{ branch.name || branch.branch }}</strong><p>{{ branch.description || '此分支暂无说明，请与开发确认测试范围。' }}</p><span class="muted">对应分支：{{ branch.branch }}</span></div>
      <h2>打包配置</h2><div class="fields"><label>环境<select v-model="form.environment"><option v-for="env in project.environments" :key="env">{{ env }}</option></select></label><label v-if="project.formats.length > 1">包格式<select v-model="form.format"><option v-for="format in project.formats" :key="format" :value="format">{{ format.toUpperCase() }}</option></select></label><label v-if="project.products">产品<select v-model="form.product"><option v-for="product in project.products" :key="product">{{ product }}</option></select></label></div>
      <template v-if="project.signing"><div class="fields"><label>签名凭据<select v-model="form.signingKey" :required="project.id === 'tappo-phone' && form.format === 'aab'"><option value="">内部测试签名</option><option v-for="key in project.signingKeys" :key="key.id" :value="key.id">{{ key.label }}</option></select></label><label>版本号（可选）<input v-model="form.versionCode" inputmode="numeric" pattern="[1-9][0-9]*" placeholder="留空沿用源码 versionCode"></label></div><p class="muted">Tappo Phone AAB 必须选择原 Google Play 上传密钥。APK 内部测试签名不能覆盖不同签名的应用。</p></template>
      <h2>分发选项</h2><div class="row"><label class="check"><input v-model="form.upload" type="checkbox">上传 DUFS</label><label class="check"><input v-model="form.notify" type="checkbox">钉钉通知</label><label v-if="project.incident" class="check"><input v-model="form.incident" type="checkbox">启用 Incident 故障上报</label></div><div class="footer"><span class="muted">下载地址与分发凭据由 Jenkins 管理。</span><button class="primary" :disabled="loading || !branch">下一步：确认打包</button></div>
    </form>
  </template>
  <p v-if="error" class="error" role="alert">{{ error }}。提交响应不明时，请先查看构建记录；再次点击确认将复用同一请求编号。</p>
</template>
