<script setup>
import { onMounted, onUnmounted, ref } from 'vue';
import { api } from '../api.js';

const props = defineProps({ row: { type: Object, required: true } });
const root = ref(null), loading = ref(false), loaded = ref(false), error = ref('');
const externalLinks = ref([]), dufsLinks = ref([]), dufsError = ref(''), dufsLoading = ref(false);
let observer, controller;

async function load() {
  if (loading.value) return;
  controller?.abort();
  controller = new AbortController();
  const signal = controller.signal;
  loading.value = true; loaded.value = false; error.value = ''; dufsError.value = ''; dufsLoading.value = false;
  externalLinks.value = []; dufsLinks.value = [];
  try {
    const build = await api(`/builds/${props.row.id}`, { signal });
    const artifacts = build.artifacts || [];
    const origin = build.publicOrigin.replace(/\/$/, '');
    externalLinks.value = artifacts.flatMap((artifact, index) => artifact.fileName === 'dufs-links.txt' ? [] : [{
      name: artifact.fileName,
      url: `${origin}/api/builds/${props.row.id}/artifacts/${index}`
    }]);
    if (!signal.aborted) loaded.value = true;
    const linksIndex = artifacts.findIndex(artifact => artifact.fileName === 'dufs-links.txt');
    if (JSON.parse(props.row.payload).upload && linksIndex >= 0) {
      dufsLoading.value = true;
      try {
        const response = await fetch(`/api/builds/${props.row.id}/artifacts/${linksIndex}`, {
          cache: 'no-store', signal: AbortSignal.any([signal, AbortSignal.timeout(120000)])
        });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const content = await response.text();
        dufsLinks.value = content.split(/\r?\n/).map(line => line.trim()).filter(line => /^https?:\/\//i.test(line));
      } catch (issue) {
        if (!signal.aborted) dufsError.value = issue.name === 'TimeoutError' ? 'DUFS 链接读取超时' : 'DUFS 链接读取失败';
      } finally { if (!signal.aborted) dufsLoading.value = false; }
    }
  } catch (issue) {
    if (!signal.aborted) error.value = issue.name === 'TimeoutError' ? '下载链接获取超时' : '下载链接获取失败';
  } finally {
    if (!signal.aborted) loading.value = false;
  }
}

function fileName(url) {
  try { return decodeURIComponent(new URL(url).pathname.split('/').pop()) || '下载文件'; }
  catch { return '下载文件'; }
}

onMounted(() => {
  if (!('IntersectionObserver' in window)) { load(); return; }
  observer = new IntersectionObserver(entries => {
    if (entries[0]?.isIntersecting) { observer.disconnect(); load(); }
  }, { rootMargin: '240px' });
  observer.observe(root.value);
});
onUnmounted(() => { observer?.disconnect(); controller?.abort(); });
</script>

<template>
  <div ref="root" class="record-links">
    <span v-if="loading && !loaded" class="muted">正在读取下载链接…</span>
    <template v-if="loaded">
      <a v-for="link in externalLinks" :key="link.url" :href="link.url" :title="link.url" target="_blank" rel="noopener noreferrer">外网下载 · {{ link.name }}</a>
      <a v-for="link in dufsLinks" :key="link" :href="link" :title="link" target="_blank" rel="noopener noreferrer">DUFS 下载 · {{ fileName(link) }}</a>
      <span v-if="dufsLoading" class="muted">正在读取 DUFS 链接…</span>
      <span v-if="!externalLinks.length && !dufsLinks.length && !dufsLoading && !dufsError" class="muted">暂无下载链接</span>
    </template>
    <span v-if="error || dufsError" class="muted">{{ error || dufsError }}</span>
    <button v-if="error || dufsError" type="button" @click="load">重试链接</button>
  </div>
</template>
