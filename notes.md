## Git for windows

```sh
git update-index --chmod=+x bin/...
```

## Gem update process

```sh
gem build file-digests.gemspec
gem push file-digests-...
gem install file-digests-...
```

## Digest functions benchmark

On a 12.5 GB set of 2859 media files (hot run, files are mostly cached in RAM), on Windows i7 laptop:

```ruby
NO-OP digest function - 0:03.550

# https://github.com/konsolebox/digest-xxhash-ruby
# I would not use non-cryptographic hash for that purpose
require 'digest/xxhash'
Digest::XXH64.new - 0:4.497

# Ruby internal implementation
Digest::SHA512.new - 0:20.832
Digest::SHA384.new - 0:20.866
Digest::SHA256.new - 0:29.534

# OpenSSL
require 'openssl'
OpenSSL::Digest.new("SHA1") - 0:15.442
OpenSSL::Digest.new("MD5") - 0:20.487

OpenSSL::Digest.new("BLAKE2b512") - 0:17.982
OpenSSL::Digest.new("BLAKE2s256") - 0:26.187

OpenSSL::Digest.new("SHA512") - 0:20.774
OpenSSL::Digest.new("SHA512-256") - 0:20.862
OpenSSL::Digest.new("SHA256") - 0:29.433

OpenSSL::Digest.new("SHA3-256") - 0:35.966
OpenSSL::Digest.new("SHA3-512") - 1:03.428

# it should be faster, I guess Windows implementation is not yet optimal
require 'digest/kangarootwelve'
Digest::KangarooTwelve.default.new - 0:46:583

# SQLite3 on external USB HDD (for the database only), files are still on SSD
# with WAL
Digest::SHA256.new - 0:33
# without WAL
Digest::SHA256.new - 7:34 (!)
```
