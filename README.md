## File-digests

A tool to check if there are any changes in your files using SHA256 sum. It's cross-platform (Linux/Windows/macOS).

If you move your files across platforms, through unreliable connections or you don't quite trust your tools, that utility will help you to spot possible errors.

It will also help you to find issues with your storage: bitrot, bad blocks, hardware or software issues.

## Install

If you are on Windows, please install Ruby for Windows first.

```sh
sudo gem install file-digests
```

## Usage

```sh
#
file-digests

#
file-digests-test

#
QUIET=false TEST_ONLY=false file-digests [path/to/firectory] [path/to/database.sqlite]
```
