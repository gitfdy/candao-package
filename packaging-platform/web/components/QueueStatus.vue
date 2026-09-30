<script setup>
import { computed, onMounted, onUnmounted, ref } from 'vue';
import { api, statusLabel } from '../api.js';

const queue = ref({ capacity: 2, running: 0, waiting: 0, items: [] });
const error = ref(''), loaded = ref(false);
const busy = computed(() => queue.value.running > 0 || queue.value.waiting > 0);
let timer, fetching = false, stopped = false;

async function refresh() {
  if (fetching || stopped) return;
  fetching = true;
  try {
    queue.value = await api('/builds/queue-status');
    error.value = ''; loaded.value = true;
  } catch (issue) { if (!stopped) error.value = issue.message; }
  finally { fetching = false; }
}

onMounted(() => { refresh(); timer = setInterval(refresh, 10000); });
onUnmounted(() => { stopped = true; clearInterval(timer); });
defineExpose({ refresh });
</script>

<template>
  <details class="queue-status" :class="{ 'is-busy': busy }">
    <summary aria-label="查看全平台打包队列">
      <span class="queue-slots" aria-hidden="true"><i v-for="slot in queue.capacity" :key="slot" :class="{ occupied: slot <= queue.running }"></i></span>
      <span>执行器</span>
      <strong v-if="loaded">{{ queue.running }}/{{ queue.capacity }}</strong>
      <span v-else>读取中</span>
      <em v-if="queue.waiting">等待 {{ queue.waiting }}</em>
      <em v-if="error" class="queue-warning">更新失败</em>
    </summary>
    <div class="queue-popover">
      <div class="queue-popover-heading"><strong>全平台打包队列</strong><small>每 10 秒更新 · {{ queue.capacity }} 个执行位</small></div>
      <p v-if="error" class="queue-error" role="alert">状态读取失败：{{ error }} <button type="button" @click="refresh">重试</button></p>
      <template v-else-if="loaded">
        <p class="queue-advice">{{ queue.waiting ? '已有任务等待，建议稍后发起打包。' : queue.running >= queue.capacity ? '执行位已满，新任务会进入等待。' : '当前有空闲执行位。' }}</p>
        <ol v-if="queue.items.length" class="queue-items">
          <li v-for="item in queue.items" :key="item.id">
            <span class="queue-item-state" :data-status="item.status">{{ item.waitingForExecutor ? '等待执行器' : statusLabel(item.status) }}</span>
            <span class="queue-item-main"><strong>{{ item.source === 'jenkins' ? '' : `#${item.id} ` }}{{ item.name }}</strong><small>{{ item.project }}<template v-if="item.actor"> · {{ item.actor }}</template></small></span>
          </li>
        </ol>
        <p v-else class="queue-empty">当前没有正在打包或等待的任务。</p>
      </template>
      <p v-else class="queue-empty">正在读取队列状态…</p>
      <small class="queue-scope">执行器和等待数来自 Jenkins。</small>
    </div>
  </details>
</template>
