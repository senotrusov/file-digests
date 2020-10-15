## File-digests

An utility to check if there are any changes in your files.

If you move your files around, perhaps across platforms, maybe through unreliable connections, or with the tools you don't quite trust, that utility will help you to verify the result and spot possible errors.

It will also help you to find issues with your storage: silent data corruption, bitflips/bitrot, bad blocks, other hardware or software faults.

It can show a list of duplicate files as well.

It is a CLI utility, written on Ruby. It's cross-platform (Linux/UNIX/Windows/macOS). It's tested to run on Ubuntu 20.04, Windows 10, and macOS Catalina.

### How it works

* Given the directory, it calculates digests (BLAKE2b512, SHA3-256, or SHA512-256) for the files it contains.
* Those digests are then kept in a SQLite database. By default, the database is stored in the same directory with the rest of the files. You could specify any other location.
* Any time later you run the tool again.
  * It will check if any file becomes corrupted or missed due to hardware/software issues.
  * It will store digests of updated files. It is assumed that if a particular file has both mtime and digest changed then it's a sign of a legitimate update, and not of a storage fault.
  * New files will be added to a database.
  * Renames will be tracked.
  * If files are missed from your storage then the tool will ask for your confirmation to remove information on those files from the database.

### Digest algorithms

* You could change the digest algorithm at any time. Transition to a new algorithm will only occur if all files pass the check by digests which were stored using the old one.
* Faster algorithms like KangarooTwelve and BLAKE3 may be added as soon as fast and stable implementation will be available in Ruby.

## Install

```sh
# Windows (please install Ruby for Windows first).
gem install file-digests

# Linux/macOS
sudo gem install file-digests
```

## Usage

```
Usage: file-digests [options] [path/to/directory] [path/to/database_file]
       By default the current directory will be operated upon, and the database file will be placed to the current directory as well.
       Should you wish to check current directory but place the database elsewhere, you could provide "." as a first argument, and the path to a database_file as a second.
    -a, --auto                       Do not ask for any confirmation.
    -d, --digest DIGEST              Select a digest algorithm to use. Default is "BLAKE2b512".
                                     You might also consider to use slower "SHA512-256" or even more slower "SHA3-256".
                                     Digest algorithm should be one of the following: BLAKE2b512, SHA3-256, SHA512-256.
                                     You only need to specify an algorithm on the first run, your choice will be saved to a database.
                                     Any time later you could specify a new algorithm to change the current one.
                                     Transition to a new algorithm will only occur if all files pass the check by digests which were stored using the old one.
    -f, --accept-fate                Accept the current state of files that are likely damaged and update their digest data.
    -h, --help                       Prints this help.
    -p, --duplicates                 Show the list of duplicate files, based on the information out of the database.
    -q, --quiet                      Less verbose output, stil report any found issues.
    -t, --test                       Perform only the test, do not modify the digest database.
    -v, --verbose                    More verbose output.
```

## Contributing

Please see our [Contributing Guidelines](CONTRIBUTING.md) for details.
