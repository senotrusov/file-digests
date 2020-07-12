## Usage

```sh
VERBOSE=true TEST_ONLY=false ruby file-digests.rb path/to/files path/to/database.sqlite
```

## Windows install

1. Install rubyinstaller

2. Open ruby shell from the start menu

```sh
gem install bundler
bundle install
```

4. In case of any problems with sqlite, try to install it manually

```sh
gem install sqlite3
```
