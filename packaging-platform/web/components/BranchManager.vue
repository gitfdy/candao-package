<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from 'vue';
import { api } from '../api.js';
const props = defineProps(['project', 'branches', 'loading', 'canEdit']);
const emit = defineEmits(['refresh']);
const search = ref(''), editing = ref(null), busy = ref(false), message = ref(''), error = ref('');
const original = ref('');
const dirty = computed(() => editing.value && JSON.stringify(editing.value) !== original.value);
function canLeave() { return !busy.value && (!dirty.value || window.confirm('分支说明尚未保存，确定放弃修改？')); }
function edit(item) { editing.value = { ...item, name: item.name || '', description: item.description || '' }; original.value = JSON.stringify(editing.value); error.value = ''; message.value = ''; }
function closeEditor() { if (canLeave()) editing.value = null; }
function beforeUnload(event) { if (dirty.value || busy.value) { event.preventDefault(); event.returnValue = ''; } }
onMounted(() => window.addEventListener('beforeunload', beforeUnload));
onBeforeUnmount(() => window.removeEventListener('beforeunload', beforeUnload));
defineExpose({ canLeave });
const filtered = computed(() => props.branches.filter(item => `${item.branch} ${item.name || ''} ${item.description || ''}`.toLowerCase().includes(search.value.toLowerCase())));
async function save() {
  busy.value = true; error.value = '';
  try {
    await api(`/projects/${props.project.id}/notes`, { method: 'PUT', body: editing.value });
    editing.value = null; message.value = '已保存，打包页将使用新的说明。'; emit('refresh');
  } catch (issue) { error.value = issue.message; }
  finally { busy.value = false; }
}
</script>
<template>
  <template v-if="editing"><button :disabled="busy" @click="closeEditor">返回列表</button><h1>编辑分支说明</h1><form class="panel" @submit.prevent="save"><label>分支<input :value="editing.branch" readonly></label><label>对应需求名称<input v-model="editing.name" required maxlength="80" :disabled="busy"></label><label>需求 / 测试说明<textarea v-model="editing.description" rows="5" maxlength="2000" :disabled="busy"></textarea></label><button class="primary" :disabled="busy">{{ busy ? '保存中…' : '保存说明' }}</button></form></template>
  <template v-else><div class="row spread page-heading"><div><h1>分支信息管理</h1><p>需求名称和说明由管理员维护。</p></div><button :disabled="loading" @click="emit('refresh')">刷新分支</button></div><div class="directory-tools"><label>搜索需求或分支<input v-model="search" type="search" placeholder="输入需求名、分支名或说明"></label><span class="muted">显示 {{ filtered.length }} / {{ branches.length }} 个分支</span></div><p v-if="loading" role="status">正在读取 GitLab…</p><div v-else class="panel record-list"><article v-for="item in filtered" :key="item.branch" class="record"><div><strong>{{ item.name || '未填写需求说明' }}</strong><div class="muted branch-code">{{ item.branch }}</div><p v-if="item.description">{{ item.description }}</p><small v-if="item.updated">{{ item.actor }} · {{ new Date(item.updated).toLocaleString() }}</small></div><button v-if="canEdit" @click="edit(item)">{{ item.name ? '编辑说明' : '填写说明' }}</button></article><p v-if="!filtered.length">没有匹配的分支。</p></div></template>
  <p v-if="message" role="status">{{ message }}</p><p v-if="error" class="error" role="alert">{{ error }}</p>
</template>
