<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue';
import { api } from './api.js';
import Select from 'primevue/select';
import MemoBook from './components/MemoBook.vue';
import BuildForm from './components/BuildForm.vue';
import BranchManager from './components/BranchManager.vue';
import BuildHistory from './components/BuildHistory.vue';
import QueueStatus from './components/QueueStatus.vue';
import DownloadStatus from './components/DownloadStatus.vue';
import { readRoute, routeUrl } from './navigation.js';

const user = ref(null), username = ref(''), password = ref('');
const guest = ref(null);
const sessionLoading = ref(true), sessionError = ref('');
const projects = ref([]), projectId = ref(''), branches = ref([]);
const page = ref('build'), error = ref(''), busy = ref(false), loading = ref(false), selectedBuild = ref(null);
const project = computed(() => projects.value.find(item => item.id === projectId.value));
const memoBook = ref(null);
const queueStatus = ref(null);
const branchManager = ref(null), buildForm = ref(null);
let historyIndex = Number(history.state?.platformIndex) || 0, returning = false;
history.replaceState({ ...history.state, platformIndex: historyIndex }, '', location.href);
function canLeave() {
  return (!memoBook.value || memoBook.value.canLeave()) && (!branchManager.value || branchManager.value.canLeave()) && (!buildForm.value || buildForm.value.canLeave());
}
function updateUrl(replace = false) {
  const url = routeUrl({ project: projectId.value, page: page.value, build: selectedBuild.value }, location.href);
  if (!replace && url === location.pathname + location.search + location.hash) return;
  if (!replace) historyIndex++;
  history[replace ? 'replaceState' : 'pushState']({ ...history.state, platformIndex: historyIndex }, '', url);
}
function restoreRoute() {
  const route = readRoute(location.search);
  const nextProject = projects.value.some(item => item.id === route.project) ? route.project : projects.value[0]?.id || '';
  const changed = nextProject !== projectId.value;
  projectId.value = nextProject;
  page.value = labels.value[route.page] ? route.page : 'build';
  selectedBuild.value = page.value === 'history' ? route.build : null;
  updateUrl(true);
  return changed;
}
function onPopState(event) {
  const targetIndex = Number(event.state?.platformIndex) || 0;
  if (returning) { returning = false; return; }
  if (!canLeave()) { returning = true; history.go(historyIndex - targetIndex); return; }
  historyIndex = targetIndex;
  if (user.value && restoreRoute()) loadBranches();
}
function changePage(key) {
  if (key === page.value && !selectedBuild.value) return;
  if (!canLeave()) return;
  page.value = key; selectedBuild.value = null;
  updateUrl();
}
async function goHome() {
  if (busy.value || sessionLoading.value) return;
  if (user.value) changePage('build');
  else {
    password.value = '';
    await resume();
  }
}
const labels = computed(() => ({
  build: '发起打包', branches: '分支信息管理', history: '构建记录',
  ...(user.value?.role === 'admin' ? { memos: '个人备忘录' } : {})
}));
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
  restoreRoute();
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
  if (!canLeave()) return;
  try { await api('/logout', { method: 'POST' }); await resume(); }
  catch (issue) { error.value = issue.message; }
}
async function resume() {
  sessionLoading.value = true; sessionError.value = '';
  user.value = null; branches.value = []; selectedBuild.value = null; page.value = 'build'; error.value = '';
  try {
    user.value = await api('/me');
    if (user.value.role === 'guest') guest.value = user.value;
  } catch (issue) {
    if (issue.status !== 401) sessionError.value = issue.message;
  } finally { sessionLoading.value = false; }
  if (user.value) {
    try { await initialize(); }
    catch (issue) { error.value = issue.message; }
  }
}
onMounted(async () => {
  window.addEventListener('platform-session-expired', sessionExpired);
  window.addEventListener('popstate', onPopState);
  await resume();
});
onUnmounted(() => { window.removeEventListener('platform-session-expired', sessionExpired); window.removeEventListener('popstate', onPopState); });
function submitted(build) {
  queueStatus.value?.refresh();
  if (build.project !== projectId.value) return;
  selectedBuild.value = build.id; page.value = 'history';
  updateUrl();
}
function changeProject(id) {
  if (id === projectId.value || !canLeave()) return;
  projectId.value = id; selectedBuild.value = null; updateUrl(); loadBranches();
}
function selectBuild(id) { selectedBuild.value = id; updateUrl(); }
</script>

<template>
  <div class="shell">
    <header class="site-header"><a class="brand-lockup" href="/" aria-label="Mobile Build 首页" @click.prevent="goHome"><strong class="brand">Mobile Build</strong><small>BUILD &amp; RELEASE CONSOLE</small></a><QueueStatus v-if="user" ref="queueStatus" /><div v-if="user" class="row header-actions"><span class="user-badge"><span class="status-dot"></span>{{ user.role === 'guest' ? '访客' : `${user.username} · ${user.role === 'admin' ? '管理员' : '构建成员'}` }}</span><button v-if="user.role === 'guest'" @click="user = null; error = ''">管理员登录</button><button v-else @click="logout">退出登录</button></div></header>
    <main v-if="sessionLoading || sessionError" class="login session-state" :aria-busy="sessionLoading">
      <p v-if="sessionLoading" role="status">正在进入工作台…</p>
      <div v-else class="panel"><p class="error" role="alert">{{ sessionError }}</p><button class="primary" @click="resume">重新连接</button></div>
    </main>
    <main v-else-if="!user" class="login">
      <section class="panel login-card">
        <div class="login-intro"><span class="eyebrow">管理员功能</span><h1>{{ guest ? '管理员登录' : '登录 Mobile Build' }}</h1><p>{{ guest ? '登录后可管理分支需求名称和变更备注。' : '登录后选择需求、发起打包并获取安装包。' }}</p></div>
        <form class="login-form" @submit.prevent="login"><label for="login-username">账号</label><input id="login-username" v-model="username" required autocomplete="username" placeholder="请输入管理员账号"><label for="login-password">密码</label><input id="login-password" v-model="password" type="password" required autocomplete="current-password" placeholder="请输入密码"><button class="primary login-submit" :disabled="busy">{{ busy ? '正在登录…' : '登录管理后台' }}</button></form>
      </section>
      <p v-if="error" class="error login-error" role="alert">{{ error }}</p>
    </main>
    <template v-else>
      <div class="workspace">
        <aside class="sidebar" aria-label="工作区导航">
          <div class="project-bar"><div><label for="project">选择项目</label></div><Select :modelValue="projectId" inputId="project" :options="projects" optionLabel="name" optionValue="id" class="full-width" @update:modelValue="changeProject" /><span class="project-meta" role="status"><span class="status-dot"></span>{{ loading ? '正在读取分支…' : `${branches.length} 个可用分支` }}</span></div>
          <nav aria-label="Mobile Build 功能导航"><button v-for="(label, key) in labels" :key="key" :aria-pressed="page === key" @click="changePage(key)">{{ label }}</button></nav>
        </aside>
        <main class="workspace-main">
        <p class="breadcrumb">工作台 <span>/</span> <template v-if="page !== 'memos'">{{ project?.name }} <span>/</span></template> {{ labels[page] }}</p>
        <div v-if="error && page !== 'memos'" role="alert" class="error">{{ error }} <button @click="loadBranches">重新读取分支</button></div>
        <Transition name="view" mode="out-in"><div v-if="project || page === 'memos'" :key="page === 'memos' ? 'memos' : `${project.id}-${page}`" class="page-content">
          <MemoBook v-if="page === 'memos' && user.role === 'admin'" ref="memoBook" :user="user" />
          <BuildForm v-else-if="page === 'build'" ref="buildForm" :project="project" :branches="branches" :loading="loading" :user-key="user.username || user.role" @submitted="submitted" />
          <BranchManager v-else-if="page === 'branches'" ref="branchManager" :project="project" :branches="branches" :loading="loading" :can-edit="user.role === 'admin'" @refresh="loadBranches" />
          <BuildHistory v-else :project="project" :selected-id="selectedBuild" @select-build="selectBuild" />
        </div></Transition>
        </main>
      </div>
    </template>
    <DownloadStatus />
  </div>
</template>
