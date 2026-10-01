<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue';
import { downloads, startDownload, cancelDownload, dismissDownload } from '../download.js';
const expanded = ref(true);
const active = computed(() => downloads.filter(item => item.status === 'running').length);
function beforeUnload(event) { if (active.value) { event.preventDefault(); event.returnValue = ''; } }
onMounted(() => window.addEventListener('beforeunload', beforeUnload));
onUnmounted(() => window.removeEventListener('beforeunload', beforeUnload));
</script>
<template>
  <Transition name="download-panel">
  <aside v-if="downloads.length" class="download-status" aria-label="下载任务">
    <button class="download-status-heading" type="button" :aria-expanded="expanded" aria-controls="download-tasks" @click="expanded = !expanded">
      <strong>下载任务 <span v-if="active">· {{ active }} 个进行中</span></strong><span>{{ expanded ? '收起' : '展开' }}</span>
    </button>
    <Transition name="download-list">
    <ul v-show="expanded" id="download-tasks" class="download-tasks">
      <li v-for="task in downloads" :key="task.key">
        <strong class="download-task-name">{{ task.name }}</strong>
        <p role="status">构建 #{{ task.buildId }} · {{ task.progress }}</p>
        <progress v-if="task.status === 'running'" :value="task.percent" max="100" :aria-label="`${task.name} 下载进度`"></progress>
        <p v-if="task.error" class="download-task-error" role="alert">{{ task.error }}</p>
        <div class="row">
          <button v-if="task.status === 'running'" type="button" @click="cancelDownload(task.key)">取消下载</button>
          <button v-if="['failed', 'cancelled'].includes(task.status)" type="button" @click="startDownload(task.buildId, task.artifact, task.index)">重新下载</button>
          <button v-if="task.status !== 'running'" type="button" @click="dismissDownload(task.key)">关闭</button>
        </div>
      </li>
    </ul>
    </Transition>
  </aside>
  </Transition>
</template>
