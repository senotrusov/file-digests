Gem::Specification.new do |s|
  s.name        = 'file-digests'
  s.version     = '0.0.1'
  s.date        = '2020-10-08'
  s.summary     = "file-digests"
  s.description = "Calculate file digests and check for the possible file corruption"
  s.authors     = ["Stanislav Senotrusov"]
  s.email       = 'stan@senotrusov.com'
  s.executables << 'file-digests'
  s.homepage    = 'https://github.com/senotrusov/file-digests'
  s.license     = 'Apache-2.0'
  s.add_runtime_dependency 'sqlite3', '>= 1.3.0'
end