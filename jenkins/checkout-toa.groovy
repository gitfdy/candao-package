// Jenkins owns both checkouts; never read or update a developer's source directory.
def call(String repository, String branch) {
  repository = repository?.trim() ?: 'https://git.can-dao.com/flutter-business/toa-pos-flutter.git'
  branch = branch?.trim() ?: 'devlop_qc'
  // Bind company credentials only to the company HTTPS Git host.
  if (!(repository ==~ /https:\/\/git\.can-dao\.com\/[A-Za-z0-9_-]+\/[A-Za-z0-9._-]+\.git/)) {
    error('TOA repository must be an HTTPS Git URL on git.can-dao.com without embedded credentials')
  }
  if (!(branch ==~ /[A-Za-z0-9][A-Za-z0-9._\/-]*/) || branch.contains('..') || branch.contains('//') || branch.endsWith('/') || branch.endsWith('.')) {
    error('Invalid TOA branch name')
  }
  def repositories = [
    [directory: 'source', url: repository, branch: branch],
    [directory: 'octopus_payment_flutter', url: 'https://git.can-dao.com/flutter-business/octopus_payment_flutter.git', branch: 'main']
  ]
  for (def repo in repositories) {
    dir(repo.directory) {
      def revision = checkout([
        $class: 'GitSCM',
        branches: [[name: "refs/heads/${repo.branch}"]],
        userRemoteConfigs: [[url: repo.url, credentialsId: 'candao-git-new']],
        extensions: []
      ])
      echo("${repo.directory}: ${repo.branch} @ ${revision.GIT_COMMIT}")
    }
  }
}

return this
