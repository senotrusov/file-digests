#  Copyright 2020 Stanislav Senotrusov <stan@senotrusov.com>
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

Gem::Specification.new do |s|
  s.name        = 'file-digests'
  s.version     = '0.0.43'
  s.date        = '2022-07-20'

  s.summary     = 'file-digests'
  s.description = 'Calculate file digests and check for the possible file corruption'
  s.authors     = ['Stanislav Senotrusov']
  s.email       = 'stan@senotrusov.com'
  s.homepage    = 'https://github.com/senotrusov/file-digests'
  s.license     = 'Apache-2.0'

  s.files       = ['lib/file-digests.rb']
  s.executables = ['file-digests']

  s.add_runtime_dependency 'openssl', '~> 3.0'
  s.add_runtime_dependency 'sqlite3', '~> 1.4'
end
