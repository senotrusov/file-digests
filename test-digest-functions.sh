#!/usr/bin/env bash

if [ ! -d .testdata ]; then
  mkdir .testdata
  dd bs=1M count=1024 </dev/urandom >.testdata/1GB-1.file
  dd bs=1M count=1024 </dev/urandom >.testdata/1GB-2.file
  dd bs=1M count=1024 </dev/urandom >.testdata/1GB-3.file
  dd bs=1M count=1024 </dev/urandom >.testdata/1GB-4.file
  dd bs=1M count=1024 </dev/urandom >.testdata/1GB-5.file
fi

ruby -Ilib bin/file-digests .testdata "$@"
