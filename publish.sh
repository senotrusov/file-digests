#!/usr/bin/env bash

#  Copyright 2012-2020 Stanislav Senotrusov <stan@senotrusov.com>
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

if ! declare -f fail > /dev/null; then
  fail() {
    echo "${BASH_SOURCE[1]}:${BASH_LINENO[0]}: in \`${FUNCNAME[1]}': Error: ${1:-"Abnormal termination"}" >&2
    exit "${2:-1}"
  }
fi

file="$(gem build file-digests.gemspec | grep "File:" | sed "s/^[[:space:]]*File:[[:space:]]//"; test "${PIPESTATUS[*]}" = "0 0 0")" || fail

if [ -n "${file}" ] && [ -f "${file}" ]; then
  sudo gem install "${file}" || fail
  sudo gem cleanup "${file}" || fail
  gem push "${file}" || fail
  rm -f file-digests-*.gem || fail
else
  fail "Unable to find ${file}"
fi
