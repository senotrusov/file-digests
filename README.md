## File-digests

A tool to check if there are any changes in your files using SHA256 sum.

If you move your files across platforms, through unreliable connections or you don't quite trust your tools, that utility will help you to spot possible errors.

It will also help you to find issues with your storage: bitrot, bad blocks, hardware or software issues.

It is written on Ruby and it's cross-platform (Windows/macOS/Linux/UNIX). I tested it on Windows 10, macOS Catalina and Ubuntu 20.04.

## Install

If you are on Windows, please install Ruby for Windows first.

```sh
sudo gem install file-digests
```

## Usage

```sh
# For the current directory:
#   1. Create database if needed (.file-digests.*)
#   2. Add new files
#   3. Check previously added files and report any found issues
#   4. Track renames
#   5. Find deleted files and ask to remove them from the database
file-digests

# Perform all the above but do not change the database, just report
file-digests-test

# Do not ask for confirmations (remove absent files from the database)
file-digests-auto

# Optional flags and arguments:
#   AUTO - Do not ask for confirmations, same as executing "file-digests-auto"
#   QUIET - less verbose, but stil report any found issues
#   TEST_ONLY - do not change the database, same as executing "file-digests-test"
AUTO=false QUIET=false TEST_ONLY=false file-digests [path/to/directory] [path/to/database_file]

# If you want to check current directory and place database elsewere,
# you could use "." as a path/to/directory following the path/to/database_file
file-digests . ~/digests/my-digest.sqlite
```

## Contributing

Please see our [Contributing Guidelines](CONTRIBUTING.md) for details.
