export function readRoute(search) {
  const params = new URLSearchParams(search);
  const pages = ['build', 'branches', 'history', 'memos'];
  const page = pages.includes(params.get('page')) ? params.get('page') : 'build';
  const id = params.get('build');
  return { project: params.get('project') || '', page, build: page === 'history' && /^[1-9]\d*$/.test(id || '') && Number.isSafeInteger(Number(id)) ? Number(id) : null };
}
export function routeUrl(route, currentUrl) {
  const url = new URL(currentUrl);
  for (const key of ['project', 'page', 'build']) url.searchParams.delete(key);
  if (route.project) url.searchParams.set('project', route.project);
  url.searchParams.set('page', route.page);
  if (route.page === 'history' && route.build) url.searchParams.set('build', route.build);
  return url.pathname + url.search + url.hash;
}
