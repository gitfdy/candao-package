<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue';
import { api } from './api.js';
import BuildForm from './components/BuildForm.vue';
import BranchManager from './components/BranchManager.vue';
import BuildHistory from './components/BuildHistory.vue';

const user = ref(null), username = ref(''), password = ref('');
const guest = ref(null);
const projects = ref([]), projectId = ref(''), branches = ref([]);
const page = ref('build'), error = ref(''), busy = ref(false), loading = ref(false), selectedBuild = ref(null);
const project = computed(() => projects.value.find(item => item.id === projectId.value));
const labels = { build: '发起打包', branches: '分支信息管理', history: '构建记录' };
let branchRequest = 0;
function sessionExpired() {
  const wasLoggedIn = Boolean(user.value);
  user.value = null; projects.value = []; projectId.value = ''; branches.value = [];
  selectedBuild.value = null; page.value = 'build'; loading.value = false; branchRequest++;
  if (wasLoggedIn) error.value = '登录已失效，请重新登录。';
}
async function loadBranches() {
  const request = ++branchRequest;
  branches.value = []; loading.value = true; error.value = '';
  try {
    const result = await api(`/projects/${projectId.value}/branches`);
    if (request === branchRequest) branches.value = result;
  } catch (issue) { if (request === branchRequest) error.value = issue.message; }
  finally { if (request === branchRequest) loading.value = false; }
}
async function initialize() {
  projects.value = await api('/projects');
  projectId.value = projects.value[0]?.id || '';
  if (projectId.value) await loadBranches();
}
async function login() {
  busy.value = true; error.value = '';
  try {
    user.value = await api('/login', { method: 'POST', body: { username: username.value, password: password.value } });
    password.value = ''; await initialize();
  } catch (issue) { error.value = issue.message; }
  finally { busy.value = false; }
}
async function logout() {
  try { await api('/logout', { method: 'POST' }); await resume(); }
  catch (issue) { error.value = issue.message; }
}
async function resume() {
  user.value = null; branches.value = []; selectedBuild.value = null; page.value = 'build'; error.value = '';
  try { user.value = await api('/me'); if (user.value.role === 'guest') guest.value = user.value; await initialize(); }
  catch (issue) { if (issue.status !== 401) error.value = issue.message; }
}
onMounted(async () => {
  window.addEventListener('platform-session-expired', sessionExpired);
  await resume();
});
onUnmounted(() => window.removeEventListener('platform-session-expired', sessionExpired));
function submitted(build) {
  if (build.project !== projectId.value) return;
  selectedBuild.value = build.id; page.value = 'history';
}
function changeProject() { selectedBuild.value = null; loadBranches(); }
</script>

<template>
  <div class="shell">
    <header><strong class="brand">餐道 · 打包中心</strong><div v-if="user" class="row"><span>{{ user.username }} · {{ user.role === 'admin' ? '管理员' : user.role === 'guest' ? '无需登录即可打包' : '构建成员' }}</span><button v-if="user.role === 'guest'" @click="user = null; error = ''">管理员登录</button><button v-else @click="logout">退出登录</button></div></header>
    <main v-if="!user" class="login">
      <h1>{{ guest ? '管理员登录' : '登录打包中心' }}</h1><p>{{ guest ? '登录后可管理分支需求名称和变更备注。' : '选择需求、打包并获取安装包。' }}</p>
      <button v-if="guest" @click="resume">返回打包平台</button>
      <form class="panel" @submit.prevent="login"><label>账号<input v-model="username" required autocomplete="username"></label><label>密码<input v-model="password" type="password" required autocomplete="current-password"></label><button class="primary" :disabled="busy">{{ busy ? '登录中…' : '登录' }}</button></form>
      <p v-if="error" class="error" role="alert">{{ error }}</p>
    </main>
    <template v-else>
      <div class="project-bar"><label for="project">当前项目</label><select id="project" v-model="projectId" @change="changeProject"><option v-for="item in projects" :key="item.id" :value="item.id">{{ item.name }}</option></select><span class="muted">三个页面共用当前项目</span></div>
      <nav aria-label="打包中心功能"><button v-for="(label, key) in labels" :key="key" :aria-pressed="page === key" @click="page = key; selectedBuild = null">{{ label }}</button></nav>
      <main>
        <p class="breadcrumb">打包中心 / {{ labels[page] }}</p>
        <div v-if="error" role="alert" class="error">{{ error }} <button @click="loadBranches">重新读取分支</button></div>
        <template v-if="project">
          <BuildForm v-if="page === 'build'" :key="project.id" :project="project" :branches="branches" :loading="loading" @submitted="submitted" />
          <BranchManager v-else-if="page === 'branches'" :key="project.id" :project="project" :branches="branches" :loading="loading" :can-edit="user.role === 'admin'" @refresh="loadBranches" />
          <BuildHistory v-else :key="project.id" :project="project" :selected-id="selectedBuild" />
        </template>
      </main>
    </template>
  </div>
</template>
