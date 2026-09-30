<script setup>
import { computed, onMounted, onBeforeUnmount, ref } from 'vue';
import { api } from '../api.js';

const props = defineProps(['user']);
const memos = ref([]), search = ref(''), editing = ref(null), original = ref('');
const busy = ref(false), loading = ref(false), error = ref(''), message = ref('');
const dirty = computed(() => editing.value && JSON.stringify(editing.value) !== original.value);
const filtered = computed(() => memos.value.filter(memo =>
  (memo.title + '\n' + memo.content).toLowerCase().includes(search.value.toLowerCase())));
function canLeave() {
  return !busy.value && (!dirty.value || window.confirm('备忘录尚未保存，确定放弃修改？'));
}
defineExpose({ canLeave });
function edit(memo) {
  if (!canLeave()) return;
  const id = memo?.id || Array.from(crypto.getRandomValues(new Uint8Array(16)), byte => byte.toString(16).padStart(2, '0')).join('');
  editing.value = memo ? { ...memo } : { id, title: '', content: '', revision: 0 };
  original.value = JSON.stringify(editing.value);
  error.value = ''; message.value = '';
}
function closeEditor() {
  if (canLeave()) editing.value = null;
}
async function load() {
  loading.value = true; error.value = '';
  try { memos.value = await api('/memos'); }
  catch (issue) { error.value = issue.message; }
  finally { loading.value = false; }
}
async function save() {
  busy.value = true; error.value = ''; message.value = '';
  try {
    const saved = await api('/memos/' + editing.value.id, { method: 'PUT', body: editing.value });
    memos.value = [saved, ...memos.value.filter(memo => memo.id !== saved.id)];
    editing.value = null; message.value = '已保存';
  } catch (issue) { error.value = issue.message; }
  finally { busy.value = false; }
}
async function remove(memo) {
  if (!window.confirm('确定删除备忘录「' + memo.title + '」？删除后无法恢复。')) return;
  busy.value = true; error.value = ''; message.value = '';
  try {
    await api('/memos/' + memo.id, { method: 'DELETE', body: { revision: memo.revision } });
    memos.value = memos.value.filter(item => item.id !== memo.id); message.value = '已删除';
  } catch (issue) { error.value = issue.message; }
  finally { busy.value = false; }
}
async function copy(content) {
  error.value = ''; message.value = '';
  try {
    if (navigator.clipboard && window.isSecureContext) await navigator.clipboard.writeText(content);
    else {
      // Public deployments also use HTTP, where the Clipboard API is unavailable.
      const area = document.createElement('textarea');
      area.value = content; area.style.position = 'fixed'; area.style.opacity = '0';
      const previous = document.activeElement;
      document.body.append(area);
      try { area.select(); if (!document.execCommand('copy')) throw new Error(); }
      finally { area.remove(); previous?.focus(); }
    }
    message.value = '已复制';
  } catch { error.value = '无法自动复制，请选中内容手动复制。'; }
}
function beforeUnload(event) {
  if (dirty.value || busy.value) { event.preventDefault(); event.returnValue = ''; }
}
onMounted(() => {
  window.addEventListener('beforeunload', beforeUnload);
  if (props.user.role !== 'guest') load();
});
onBeforeUnmount(() => window.removeEventListener('beforeunload', beforeUnload));
</script>

<template>
  <div class="row spread page-heading">
    <div><h1>个人备忘录</h1><p>记录常用命令和操作说明，跨项目使用，仅当前账号可见。</p></div>
    <button v-if="user.role !== 'guest' && !editing" class="primary" :disabled="busy || loading" @click="edit(null)">添加备忘录</button>
  </div>
  <p v-if="user.role === 'guest'" class="panel">请先通过右上角登录，再使用个人备忘录。</p>
  <template v-else>
    <form v-if="editing" class="panel memo-editor" @submit.prevent="save">
      <label for="memo-title">标题</label>
      <input id="memo-title" v-model="editing.title" required maxlength="100" :disabled="busy" placeholder="例如：Windows 打包常用命令">
      <label for="memo-content">内容 / 命令</label>
      <textarea id="memo-content" v-model="editing.content" rows="14" maxlength="20000" :disabled="busy" spellcheck="false"></textarea>
      <div class="row"><button class="primary" :disabled="busy || !editing.title.trim()">{{ busy ? '保存中…' : '保存' }}</button><button type="button" :disabled="busy" @click="closeEditor">返回列表</button></div>
    </form>
    <template v-else>
      <div class="directory-tools"><label>搜索备忘录<input v-model="search" type="search" placeholder="搜索标题或命令"></label><button :disabled="loading || busy" @click="load">刷新</button></div>
      <p v-if="loading" role="status">正在读取备忘录…</p>
      <div v-else class="memo-list">
        <article v-for="memo in filtered" :key="memo.id" class="panel">
          <div class="row spread"><h2>{{ memo.title }}</h2><small>{{ new Date(memo.updated).toLocaleString() }}</small></div>
          <pre class="memo-content">{{ memo.content }}</pre>
          <div class="row"><button :disabled="busy" @click="copy(memo.content)">复制内容</button><button :disabled="busy" @click="edit(memo)">编辑</button><button :disabled="busy" @click="remove(memo)">删除</button></div>
        </article>
        <p v-if="!filtered.length">{{ search ? '没有匹配的备忘录。' : '还没有备忘录，添加一条常用命令吧。' }}</p>
      </div>
    </template>
    <p v-if="message" role="status">{{ message }}</p>
    <p v-if="error" class="error" role="alert">{{ error }}</p>
  </template>
</template>

<style scoped>
.memo-list { display: grid; gap: 16px; }
.memo-editor { display: grid; gap: 12px; }
.memo-content { white-space: pre-wrap; overflow-wrap: anywhere; max-height: 360px; overflow: auto; background: #f3f7f5; color: #243a34; padding: 16px; border-radius: 8px; }
textarea, .memo-content { font-family: ui-monospace, SFMono-Regular, Consolas, monospace; tab-size: 2; }
h2 { overflow-wrap: anywhere; }
</style>
