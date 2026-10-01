<script setup>
import { computed, onMounted, onUnmounted, ref } from 'vue';
import { api, statusLabel } from '../api.js';

const queue = ref({ capacity: 2, running: 0, waiting: 0, items: [] });
const error = ref(''), loaded = ref(false);
const root = ref(null), expanded = ref(false), lastUpdated = ref(0), now = ref(Date.now());
const stale = computed(() => Boolean(error.value) || (loaded.value && now.value - lastUpdated.value > 30000));
const busy = computed(() => queue.value.running > 0 || queue.value.waiting > 0);
let timer, fetching = false, stopped = false;

async function refresh() {
  if (fetching || stopped) return;
  fetching = true;
  try {
    queue.value = await api('/builds/queue-status');
    error.value = ''; loaded.value = true; lastUpdated.value = Date.now(); now.value = lastUpdated.value;
  } catch (issue) { if (!stopped) error.value = issue.message; }
  finally { fetching = false; }
}

function closeOnOutside(event) { if (root.value && !root.value.contains(event.target)) expanded.value = false; }
function closeOnEscape(event) { if (event.key === 'Escape' && expanded.value) { expanded.value = false; root.value?.querySelector('button')?.focus(); } }
onMounted(() => { refresh(); timer = setInterval(() => { now.value = Date.now(); refresh(); }, 10000); document.addEventListener('pointerdown', closeOnOutside); document.addEventListener('keydown', closeOnEscape); });
onUnmounted(() => { stopped = true; clearInterval(timer); document.removeEventListener('pointerdown', closeOnOutside); document.removeEventListener('keydown', closeOnEscape); });
defineExpose({ refresh });
</script>

<template>
  <div ref="root" class="queue-status" :class="{ 'is-busy': busy, 'is-stale': stale, 'is-open': expanded }">
    <button class="queue-trigger" type="button" aria-label="查看全平台打包队列" :aria-expanded="expanded" aria-controls="build-queue-panel" @click="expanded = !expanded">
      <span v-if="!stale" class="queue-slots" aria-hidden="true"><i v-for="slot in queue.capacity" :key="slot" :class="{ occupied: slot <= queue.running }"></i></span>
      <span>{{ stale ? '打包队列' : '打包中' }}</span>
      <strong v-if="loaded && !stale">{{ queue.running }}/{{ queue.capacity }}</strong>
      <span v-else-if="!stale">读取中</span>
      <em v-if="queue.waiting && !stale">等待 {{ queue.waiting }}</em>
      <em v-if="stale" class="queue-warning">{{ loaded ? '状态已过期' : '暂不可用' }}</em>
      <svg class="queue-chevron" viewBox="0 0 12 12" fill="none" aria-hidden="true"><path d="M2.5 4.5 6 8l3.5-3.5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" /></svg>
    </button>
    <Transition name="popover">
    <div v-if="expanded" id="build-queue-panel" class="queue-popover">
      <div class="queue-popover-heading"><strong>全平台打包队列</strong><small>{{ queue.capacity }} 个执行位</small></div>
      <p v-if="stale" class="queue-error" role="alert">{{ error ? `状态读取失败：${error}` : '状态更新延迟，请刷新后判断是否发起打包。' }} <button type="button" @click="refresh">重试</button></p>
      <template v-else-if="loaded">
        <p class="queue-advice">{{ queue.waiting ? '已有任务等待，建议稍后发起打包。' : queue.running >= queue.capacity ? '执行位已满，新任务会进入等待。' : '当前有空闲执行位。' }}</p>
        <ol v-if="queue.items.length" class="queue-items">
          <li v-for="item in queue.items" :key="item.id">
            <span class="queue-item-state" :data-status="item.status">{{ item.waitingForExecutor ? '等待执行器' : statusLabel(item.status) }}</span>
            <span class="queue-item-main"><strong>{{ item.source === 'jenkins' ? '' : `#${item.id} ` }}{{ item.name }}</strong><small>{{ item.project }}<template v-if="item.actor"> · {{ item.actor }}</template></small></span>
          </li>
        </ol>

      </template>
      <p v-else class="queue-empty">正在读取队列状态…</p>
      <small v-if="lastUpdated" class="queue-scope">最后更新：{{ new Date(lastUpdated).toLocaleTimeString() }}</small>

    </div>
    </Transition>
  </div>
</template>
