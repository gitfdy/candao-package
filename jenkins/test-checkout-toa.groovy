// Offline contract check: use Jenkins step stubs; no network or Windows access.
def calls = []
def directory = ''
def binding = new Binding([
  dir: { String name, Closure action -> directory = name; action() },
  checkout: { Map config -> calls << [directory: directory, config: config]; [GIT_COMMIT: 'test-sha'] },
  echo: { String text -> },
  error: { String message -> throw new IllegalArgumentException(message) }
])
def pipeline = new GroovyShell(binding).evaluate(new File('jenkins/checkout-toa.groovy'))
pipeline.call('', '')
assert calls*.directory == ['source', 'octopus_payment_flutter']
assert calls*.config*.userRemoteConfigs.flatten()*.credentialsId == ['candao-git-new', 'candao-git-new']
assert calls[0].config.userRemoteConfigs[0].url == 'https://git.can-dao.com/flutter-business/toa-pos-flutter.git'
assert calls[0].config.branches[0].name == 'refs/heads/devlop_qc'
assert calls[1].config.userRemoteConfigs[0].url == 'https://git.can-dao.com/flutter-business/octopus_payment_flutter.git'
assert calls[1].config.branches[0].name == 'refs/heads/main'
calls.clear()
pipeline.call('https://git.can-dao.com/flutter-business/toa-pos-flutter.git', 'feature/build')
assert calls[0].config.branches[0].name == 'refs/heads/feature/build'
for (def input in [
  ['D:/work/toa-pos-flutter', 'main'],
  ['https://example.com/repo.git', 'main'],
  ['https://user:secret@git.can-dao.com/flutter-business/toa-pos-flutter.git', 'main'],
  ['', '../main']
]) {
  calls.clear()
  try { pipeline.call(*input); assert false: 'Invalid input accepted' }
  catch (IllegalArgumentException expected) { assert calls.empty }
}
calls.clear()
binding.setVariable('checkout', { Map config -> throw new IllegalStateException('Authentication failed') })
try { pipeline.call('', ''); assert false: 'Checkout failure swallowed' }
catch (IllegalStateException expected) { assert calls.empty }
println 'PASS: remote TOA/dependency checkout, branch selection, credential scope and failure propagation'

for (def platform in ['windows', 'android']) {
  def source = new File("jenkins/${platform}.Jenkinsfile").text
  assert source.contains("if (\$env:PROJECT -ne 'toa-pos') { Checkout-Source \$repo }")
  assert source.contains("load 'jenkins/checkout-toa.groovy'")
  assert source.contains('toaCheckout.call(params.REPOSITORY_URL, params.BRANCH)')
}
