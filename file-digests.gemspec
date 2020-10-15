Gem::Specification.new do |s|
  s.name        = 'file-digests'
  s.version     = '0.0.28'
  s.date        = '2020-10-15'

  s.summary     = 'file-digests'
  s.description = 'Calculate file digests and check for the possible file corruption'
  s.authors     = ['Stanislav Senotrusov']
  s.email       = 'stan@senotrusov.com'
  s.homepage    = 'https://github.com/senotrusov/file-digests'
  s.license     = 'Apache-2.0'

  s.files       = ['lib/file-digests.rb']
  s.executables = ['file-digests']

  s.add_runtime_dependency 'openssl', '~> 2.1'
  s.add_runtime_dependency 'sqlite3', '~> 1.3'
end
