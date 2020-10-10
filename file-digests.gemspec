Gem::Specification.new do |s|
  s.name        = 'file-digests'
  s.version     = '0.0.21'
  s.date        = '2020-10-08'
  s.summary     = 'file-digests'
  s.description = 'Calculate file digests and check for the possible file corruption'
  s.authors     = ['Stanislav Senotrusov']
  s.email       = 'stan@senotrusov.com'
  s.files       = ['lib/file-digests.rb']
  s.executables = ['file-digests', 'file-digests-auto', 'file-digests-show-duplicates', 'file-digests-test']
  s.homepage    = 'https://github.com/senotrusov/file-digests'
  s.license     = 'Apache-2.0'
  s.add_runtime_dependency 'sqlite3', '>= 1.3.0'
end
