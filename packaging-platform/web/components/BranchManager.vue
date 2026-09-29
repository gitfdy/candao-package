<script setup>
import { ref, computed } from 'vue';
import { api } from '../api.js';
const props = defineProps(['project', 'branches', 'loading', 'canEdit']);
const emit = defineEmits(['refresh']);
const search = ref(''), editing = ref(null), busy = ref(false), message = ref(''), error = ref('');
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
  <template v-if="editing"><button :disabled="busy" @click="editing = null">返回列表</button><h1>编辑分支说明</h1><form class="panel" @submit.prevent="save"><label>分支<input :value="editing.branch" readonly></label><label>对应需求名称<input v-model="editing.name" required maxlength="80"></label><label>需求 / 测试说明<textarea v-model="editing.description" rows="5" maxlength="2000"></textarea></label><button class="primary" :disabled="busy">{{ busy ? '保存中…' : '保存说明' }}</button></form></template>
  <template v-else><div class="row spread"><div><h1>分支信息管理</h1><p>远端分支自动读取，说明由管理员维护。</p></div><button :disabled="loading" @click="emit('refresh')">刷新分支</button></div><label>搜索需求或分支<input v-model="search" placeholder="输入需求名或分支名"></label><p v-if="loading" role="status">正在读取 GitLab…</p><div v-else class="panel"><article v-for="item in filtered" :key="item.branch" class="record"><div><strong>{{ item.name || '未填写需求说明' }}</strong><div class="muted">{{ item.branch }}</div><p>{{ item.description || '待补充说明' }}</p><small v-if="item.updated">{{ item.actor }} · {{ new Date(item.updated).toLocaleString() }}</small></div><button v-if="canEdit" @click="editing = { ...item, name: item.name || '', description: item.description || '' }; error = ''; message = ''">{{ item.name ? '编辑说明' : '填写说明' }}</button></article><p v-if="!filtered.length">没有匹配的分支。</p></div></template>
  <p v-if="message" role="status">{{ message }}</p><p v-if="error" class="error" role="alert">{{ error }}</p>
</template>
