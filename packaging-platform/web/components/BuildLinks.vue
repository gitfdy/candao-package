<script setup>
import { onMounted, onUnmounted, ref } from 'vue';
import { api } from '../api.js';
import { downloads, startDownload, downloadKey } from '../download.js';
import { copyText } from '../clipboard.js';

const props = defineProps({ row: { type: Object, required: true }, build: Object });
const root = ref(null), loading = ref(false), loaded = ref(false), error = ref('');
const externalLinks = ref([]), dufsLinks = ref([]), dufsError = ref(''), dufsLoading = ref(false);
const copyMessage = ref('');
const isDownloading = index => downloads.some(task => task.key === downloadKey(props.row.id, index) && task.status === 'running');
let observer, controller;

async function load() {
  if (loading.value) return;
  controller?.abort();
  controller = new AbortController();
  const signal = controller.signal;
  loading.value = true; loaded.value = false; error.value = ''; dufsError.value = ''; dufsLoading.value = false;
  externalLinks.value = []; dufsLinks.value = [];
  try {
    const build = props.build || await api(`/builds/${props.row.id}`, { signal: AbortSignal.any([signal, AbortSignal.timeout(45000)]) });
    const artifacts = build.artifacts || [];
    // Keep original artifact indices for the download API; omit build metadata.
    externalLinks.value = artifacts.flatMap((artifact, index) => !/\.(apk|aab|exe)$/i.test(artifact.fileName) ? [] : [{
      name: artifact.fileName,
      artifact,
      index
    }]);
    if (!signal.aborted) loaded.value = true;
    const linksIndex = artifacts.findIndex(artifact => artifact.fileName === 'dufs-links.txt');
    if (linksIndex >= 0) {
      dufsLoading.value = true;
      try {
        const response = await api(`/builds/${props.row.id}/dufs-links`, {
          signal: AbortSignal.any([signal, AbortSignal.timeout(120000)])
        });
        dufsLinks.value = response.links;
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

async function copyLink(link) {
  try { await copyText(link); copyMessage.value = 'DUFS 地址已复制'; }
  catch (issue) { copyMessage.value = issue.message; }
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
  <div ref="root" class="record-links download-links">
    <span v-if="loading && !loaded" class="muted">正在读取下载链接…</span>
    <template v-if="loaded">
      <div v-for="link in externalLinks" :key="link.index" class="download-option">
        <small v-if="externalLinks.length > 1" class="download-file-name">{{ link.name }}</small>
        <button class="download-action download-external" type="button" :title="link.name" :aria-label="`外网下载 ${link.name}`" :disabled="isDownloading(link.index)" @click="startDownload(row.id, link.artifact, link.index)">{{ isDownloading(link.index) ? '下载中…' : '外网下载' }}</button>
      </div>
      <div v-for="link in dufsLinks" :key="link" class="download-option">
        <small v-if="dufsLinks.length > 1" class="download-file-name">{{ fileName(link) }}</small>
        <div class="download-button-group"><a class="download-action" :href="link" :title="fileName(link)" :aria-label="`DUFS 下载 ${fileName(link)}`" target="_blank" rel="noopener noreferrer">DUFS 下载</a><button class="download-copy" type="button" :aria-label="`复制 ${fileName(link)} 的 DUFS 链接`" @click="copyLink(link)">复制链接</button></div>
      </div>

      <span v-if="copyMessage" class="muted" role="status">{{ copyMessage }}</span>
      <span v-if="dufsLoading" class="muted">正在读取 DUFS 链接…</span>
      <span v-if="!externalLinks.length && !dufsLinks.length && !dufsLoading && !dufsError" class="muted">暂无下载链接</span>
    </template>
    <span v-if="error || dufsError" class="muted">{{ error || dufsError }}</span>
    <button v-if="error || dufsError" type="button" @click="load">重试链接</button>
  </div>
</template>
