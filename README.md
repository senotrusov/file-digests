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
#   1. Creates database if needed (.file-digests.*)
#   2. Adds new files
#   3. Checks previously added files and reports any found issues
#   4. Tracks renames
#   5. Finds deleted files and asks to removed them from the database
file-digests

# Performs all the above but do not changes the database, just reports.
file-digests-test

# Optional flags and arguments
#   QUIET - less verbose, but stil lreport any found issues
#   TEST_ONLY - the same as calling "file-digests-test"
QUIET=false TEST_ONLY=false file-digests [path/to/directory] [path/to/database_file]

# If you want to check current directory but to place database elsewere,
# you could use "." as a path/to/directory following the path/to/database_file
file-digests . ~/digests/my-digest.sqlite
```

## Contributing

Please see our [Contributing Guidelines](CONTRIBUTING.md) for details.
