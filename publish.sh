#!/usr/bin/env bash

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
else
  fail "Unable to find ${file}"
fi
