// Check the build contract, not a branch-name allowlist: main can gain support later.
export async function kioskSupport(remotes, project, branch, product) {
  const script = await remotes.sourceFile(project, branch, 'scripts/build_windows.bat');
  const productArgument = /^if\s+\/i\s+"%~1"=="--product"\s*\(/im.test(script || '');
  const productDefine = (script || '').includes('--dart-define=product_type=%PRODUCT_TYPE%');
  let supported = productArgument && productDefine;
  if (supported && product === 'kiosk') {
    const config = await remotes.sourceFile(project, branch, 'lib/core/config/product_config.dart');
    supported = /String\.fromEnvironment\(\s*['"]product_type['"]/.test(config || '') &&
      (config || '').includes('ProductType.kiosk');
  }
  const reason = supported ? '' : product === 'kiosk'
    ? '该分支尚未实现 Kiosk 打包支持，请选择已支持 Kiosk 的分支，或先在应用仓库补齐双产品支持。切换环境无法解决此问题。'
    : '该分支的打包脚本不支持平台使用的产品参数，请先更新应用仓库的打包脚本。';
  return { supported, reason };
}
