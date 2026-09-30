<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue';
import { api } from './api.js';
import Select from 'primevue/select';
import MemoBook from './components/MemoBook.vue';
import BuildForm from './components/BuildForm.vue';
import BranchManager from './components/BranchManager.vue';
import BuildHistory from './components/BuildHistory.vue';

const user = ref(null), username = ref(''), password = ref('');
const guest = ref(null);
const projects = ref([]), projectId = ref(''), branches = ref([]);
const page = ref('build'), error = ref(''), busy = ref(false), loading = ref(false), selectedBuild = ref(null);
const project = computed(() => projects.value.find(item => item.id === projectId.value));
const memoBook = ref(null);
function changePage(key) {
  if (memoBook.value && !memoBook.value.canLeave()) return;
  page.value = key; selectedBuild.value = null;
}
const labels = { build: '发起打包', branches: '分支信息管理', history: '构建记录', memos: '个人备忘录' };
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
  if (memoBook.value && !memoBook.value.canLeave()) return;
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
    <header class="site-header"><div class="brand-lockup"><strong class="brand">Mobile Build</strong><small>BUILD &amp; RELEASE CONSOLE</small></div><div v-if="user" class="row header-actions"><span class="user-badge"><span class="status-dot"></span>{{ user.username }} · {{ user.role === 'admin' ? '管理员' : user.role === 'guest' ? '访客' : '构建成员' }}</span><button v-if="user.role === 'guest'" @click="user = null; error = ''">管理员登录</button><button v-else @click="logout">退出登录</button></div></header>
    <main v-if="!user" class="login">
      <section class="panel login-card">
        <button v-if="guest" class="login-back" @click="resume"><span aria-hidden="true">←</span> 返回打包平台</button>
        <div class="login-intro"><span class="eyebrow">管理员功能</span><h1>{{ guest ? '管理员登录' : '登录 Mobile Build' }}</h1><p>{{ guest ? '登录后可管理分支需求名称和变更备注。' : '登录后选择需求、发起打包并获取安装包。' }}</p></div>
        <form class="login-form" @submit.prevent="login"><label for="login-username">账号</label><input id="login-username" v-model="username" required autocomplete="username" placeholder="请输入管理员账号"><label for="login-password">密码</label><input id="login-password" v-model="password" type="password" required autocomplete="current-password" placeholder="请输入密码"><button class="primary login-submit" :disabled="busy">{{ busy ? '正在登录…' : '登录管理后台' }}</button></form>
      </section>
      <p v-if="error" class="error login-error" role="alert">{{ error }}</p>
    </main>
    <template v-else>
      <div class="workspace">
        <aside class="sidebar" aria-label="工作区导航">
          <div class="project-bar"><div><span class="eyebrow">当前工作区</span><label for="project">选择项目</label></div><Select v-model="projectId" inputId="project" :options="projects" optionLabel="name" optionValue="id" class="full-width" @change="changeProject" /><span class="project-meta"><span class="status-dot"></span>{{ branches.length }} 个可用分支</span></div>
          <nav aria-label="Mobile Build 功能导航"><button v-for="(label, key) in labels" :key="key" :aria-pressed="page === key" @click="changePage(key)">{{ label }}</button></nav>
        </aside>
        <main class="workspace-main">
        <p class="breadcrumb">工作台 <span>/</span> <template v-if="page !== 'memos'">{{ project?.name }} <span>/</span></template> {{ labels[page] }}</p>
        <div v-if="error && page !== 'memos'" role="alert" class="error">{{ error }} <button @click="loadBranches">重新读取分支</button></div>
        <Transition name="view" mode="out-in"><div v-if="project || page === 'memos'" :key="page === 'memos' ? 'memos' : `${project.id}-${page}`" class="page-content">
          <MemoBook v-if="page === 'memos'" ref="memoBook" :user="user" />
          <BuildForm v-else-if="page === 'build'" :project="project" :branches="branches" :loading="loading" @submitted="submitted" />
          <BranchManager v-else-if="page === 'branches'" :project="project" :branches="branches" :loading="loading" :can-edit="user.role === 'admin'" @refresh="loadBranches" />
          <BuildHistory v-else :project="project" :selected-id="selectedBuild" />
        </div></Transition>
        </main>
      </div>
    </template>
  </div>
</template>
