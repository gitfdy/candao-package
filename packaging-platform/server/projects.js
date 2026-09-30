// These values mirror the checked-in Jenkinsfiles. Job names may be overridden locally.
const repository = name => `https://git.can-dao.com/flutter-business/${name}.git`;
export const projects = [
  { id: 'toa-pos', name: 'TOA POS · Windows', job: 'TOA-POS-Windows', gitlab: 'flutter-business/toa-pos-flutter', repository: repository('toa-pos-flutter'), environments: ['test-prod', 'pre-prod', 'release', 'debug', 'release-debug'], formats: ['exe'] },
  { id: 'kiosk', name: '自助收银 · Windows', job: 'TOA-KIOSK-WINDOWS', gitlab: 'flutter-business/self-checkout', repository: repository('self-checkout'), environments: ['staging', 'test-prod', 'release', 'debug'], formats: ['exe'], products: ['kiosk', 'self_checkout'] },
  { id: 'hpos', name: '手持 POS · Android', job: 'TOA-HPOS-Android', gitlab: 'flutter-business/flutter-hpos', environments: ['test-prod', 'pre-prod', 'release', 'debug'], formats: ['apk'], environmentParameter: 'BUILD_TYPE' },
  { id: 'tappo', name: 'Tappo · Android', job: 'TAPPO-Android', gitlab: 'flutter-business/tappo', environments: ['qc', 'beta', 'gray', 'release'], formats: ['apk', 'aab'], signing: true },
  { id: 'tappo-phone', name: 'Tappo Phone · Android', job: 'TAPPO-PHONE-Android', gitlab: 'flutter-business/tappo_phone', environments: ['qc', 'prod'], formats: ['apk', 'aab'], signing: true }
];
export function fail(message, statusCode = 400) {
  throw Object.assign(new Error(message), { statusCode });
}
export function buildParameters(project, input, signingKeys = []) {
  if (!project.environments.includes(input.environment)) fail('不支持此环境');
  if (!project.formats.includes(input.format)) fail('不支持此包格式');
  if (typeof input.branch !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(input.branch) || input.branch.includes('..') || input.branch.length > 250) fail('无效分支');
  for (const key of ['upload', 'notify']) {
    if (input[key] !== undefined && typeof input[key] !== 'boolean') fail('无效开关');
  }
  const parameters = {
    BRANCH: input.branch,
    [project.environmentParameter || 'ENVIRONMENT']: input.environment,
    UPLOAD_DUFS: String(input.upload === true), SEND_DINGTALK: String(input.notify === true)
  };
  if (project.repository) parameters.REPOSITORY_URL = project.repository;
  if (project.id === 'toa-pos') parameters.ENABLE_INCIDENT_UPLOAD = 'false';
  if (project.products) {
    if (!project.products.includes(input.product)) fail('请选择产品');
    parameters.PRODUCT = input.product;
  }
  if (project.signing) {
    const key = input.signingKey || '';
    if (key && !signingKeys.some(item => item.id === key)) fail('无效签名凭据');
    if (project.id === 'tappo-phone' && input.format === 'aab' && !key) fail('Tappo Phone AAB 必须选择原 Google Play 上传密钥');
    if (input.versionCode && !/^[1-9][0-9]{0,9}$/.test(input.versionCode)) fail('版本号必须是正整数');
    if (Number(input.versionCode) > 2100000000) fail('版本号超出 Android 上限');
    parameters.PACKAGE_FORMAT = input.format;
    parameters.SIGNING_KEY = key;
    parameters.VERSION_CODE = input.versionCode || '';
  }
  return parameters;
}
