# encoding: UTF-8

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

require "date"
require "digest"
require "fileutils"
require "openssl"
require "optparse"
require "set"
require "sqlite3"

class FileDigests
  VERSION = Gem.loaded_specs["file-digests"]&.version&.to_s
  DIGEST_ALGORITHMS = ["BLAKE2b512", "SHA3-256", "SHA512-256"]
  LEGACY_DIGEST_ALGORITHMS = ["SHA512", "SHA256"]

  def self.canonical_digest_algorithm_name(string)
    if string
      algorithms = DIGEST_ALGORITHMS + LEGACY_DIGEST_ALGORITHMS
      index = algorithms.map(&:downcase).index(string.downcase)
      index && algorithms[index]
    end
  end

  def canonical_digest_algorithm_name string
    self.class.canonical_digest_algorithm_name string
  end

  def self.digest_algorithms_list_text
    "Digest algorithm should be one of the following: #{DIGEST_ALGORITHMS.join ", "}"
  end

  def self.parse_cli_options
    options = {}

    OptionParser.new do |opts|
      opts.banner = [
        "Usage: file-digests [options] [path/to/directory] [path/to/database_file]",
        "       By default the current directory will be operated upon, and the database file will be placed to the current directory as well.",
        "       Should you wish to check current directory but place the database elsewhere, you could provide \".\" as a first argument, and the path to a database_file as a second."
      ].join "\n"

      opts.on("-a", "--auto", "Do not ask for any confirmation.") do
        options[:auto] = true
      end

      opts.on(
        "-d", "--digest DIGEST",
        'Select a digest algorithm to use. Default is "BLAKE2b512".',
        'You might also consider to use slower "SHA512-256" or even more slower "SHA3-256".',
        "#{digest_algorithms_list_text}.",
        "You only need to specify an algorithm on the first run, your choice will be saved to a database.",
        "Any time later you could specify a new algorithm to change the current one.",
        "Transition to a new algorithm will only occur if all files pass the check by digests which were stored using the old one."
      ) do |value|
        digest_algorithm = canonical_digest_algorithm_name(value)
        unless DIGEST_ALGORITHMS.include?(digest_algorithm)
          STDERR.puts "ERROR: #{digest_algorithms_list_text}"
          exit 1
        end
        options[:digest_algorithm] = digest_algorithm
      end

      opts.on("-f", "--accept-fate", "Accept the current state of files that are likely damaged and update their digest data.") do
        options[:accept_fate] = true
      end

      opts.on("-h", "--help", "Prints this help.") do
        puts opts
        exit
      end

      opts.on("-p", "--duplicates", "Show the list of duplicate files, based on the information out of the database.") do
        options[:action] = :show_duplicates
      end

      opts.on("-q", "--quiet", "Less verbose output, stil report any found issues.") do
        options[:quiet] = true
      end

      opts.on(
        "-t", "--test",
        "Perform a test to verify directory contents.",
        "Compare actual files with the stored digests, check if any files are missing.",
        "Digest database will not be modified."
      ) do
        options[:test_only] = true
      end

      opts.on("-v", "--verbose", "More verbose output.") do
        options[:verbose] = true
      end

    end.parse!
    options
  end

  def self.run_cli_utility
    options = parse_cli_options

    file_digests = self.new ARGV[0], ARGV[1], options
    file_digests.send(options[:action] || :perform_check)
    file_digests.close_database
  end

  def initialize files_path, digest_database_path, options = {}
    @options = options
    @user_input_wait_time = 0

    initialize_paths files_path, digest_database_path
    initialize_database

    @db.transaction(:exclusive) do
      if db_digest_algorithm = get_metadata("digest_algorithm")
        if @digest_algorithm = canonical_digest_algorithm_name(db_digest_algorithm)
          if @options[:digest_algorithm] && @options[:digest_algorithm] != @digest_algorithm
            @new_digest_algorithm = @options[:digest_algorithm]
          end
        else
          raise "Database contains data for unsupported digest algorithm: #{db_digest_algorithm}"
        end
      else
        @digest_algorithm = (@options[:digest_algorithm] || "BLAKE2b512")
        set_metadata "digest_algorithm", @digest_algorithm
      end
    end
    puts "Using #{@digest_algorithm} digest algorithm" if @options[:verbose]
  end

  def perform_check
    measure_time do
      perhaps_transaction(@new_digest_algorithm, :exclusive) do
        @counters = {good: 0, updated: 0, renamed: 0, likely_damaged: 0, exceptions: 0}

        walk_files(@files_path) do |filename|
          process_file filename
        end

        nested_transaction do
          puts "Tracking renames..." if @options[:verbose]
          track_renames
        end

        if any_missing_files?
          if any_exceptions?
            STDERR.puts "Due to previously occurred errors, missing files will not removed from the database."
          else
            report_missing_files
            if !@options[:test_only] && (@options[:auto] || confirm("Remove missing files from the database"))
              nested_transaction do
                puts "Removing missing files..." if @options[:verbose]
                remove_missing_files
              end
            end
          end
        end

        if @new_digest_algorithm && !@options[:test_only]
          if any_missing_files? || any_likely_damaged? || any_exceptions?
            STDERR.puts "ERROR: New digest algorithm will not be in effect until there are files that are missing, likely damaged, or processed with an exception."
          else
            puts "Updating database to a new digest algorithm..." if @options[:verbose]
            digests_update_digests_to_new_digests
            set_metadata "digest_algorithm", @new_digest_algorithm
            puts "Transition to a new digest algorithm complete: #{@new_digest_algorithm}"
          end
        end

        if any_likely_damaged? || any_exceptions?
          STDERR.puts "PLEASE REVIEW ERRORS THAT WERE OCCURRED!"
          STDERR.puts "A list of errors is also saved in a file: #{@error_log_path}"
        end

        print_counters

        if any_missing_files? || any_likely_damaged? || any_exceptions?
          $FILE_DIGESTS_EXIT_STATUS=1
        end
      end

      puts "Performing database maintenance..." if @options[:verbose]
      execute "PRAGMA optimize"
      execute "VACUUM"
      execute "PRAGMA wal_checkpoint(TRUNCATE)"
    end
  end

  def show_duplicates
    current_digest = nil
    digests_select_duplicates.each do |found|
      if current_digest != found["digest"]
        puts "" if current_digest
        current_digest = found["digest"]
        puts "#{found["digest"]}:"
      end
      puts "  #{found["filename"]}"
    end
  end

  def close_database
    @statements.each(&:close)
    @db.close
    hide_database_files
  end

  private

  def initialize_paths files_path, digest_database_path
    @files_path = realpath(files_path || ".")

    unless File.directory?(@files_path) && File.readable?(@files_path)
      raise "ERROR: Files path must be a readable directory"
    end

    @start_time_filename_string = Time.now.strftime("%Y-%m-%d %H-%M-%S")

    @error_log_path = "#{@files_path}#{File::SEPARATOR}file-digests errors #{@start_time_filename_string}.txt"
    @missing_files_path = "#{@files_path}#{File::SEPARATOR}file-digests missing files #{@start_time_filename_string}.txt"

    @digest_database_path = digest_database_path ? realdirpath(digest_database_path) : @files_path

    if File.directory?(@digest_database_path)
      @digest_database_path += "#{File::SEPARATOR}.file-digests.sqlite"
    end

    @digest_database_files = [
      @digest_database_path,
      "#{@digest_database_path}-wal",
      "#{@digest_database_path}-shm"
    ]

    @skip_files = @digest_database_files + [
      @error_log_path,
      @missing_files_path
    ]

    puts "Checking file digests in: #{@files_path}" unless @options[:quiet]
    puts "Database location: #{@digest_database_path}" if @options[:verbose]
  end

  def initialize_database
    @db = SQLite3::Database.new @digest_database_path
    @db.results_as_hash = true
    @db.busy_timeout = 5000
    @statements = []

    execute "PRAGMA encoding = 'UTF-8'"
    execute "PRAGMA locking_mode = 'EXCLUSIVE'"
    execute "PRAGMA journal_mode = 'WAL'"
    execute "PRAGMA synchronous = 'NORMAL'"
    execute "PRAGMA cache_size = '5000'"

    integrity_check

    @db.transaction(:exclusive) do
      metadata_table_was_created = false
      unless table_exist?("metadata")
        execute "CREATE TABLE metadata (
          key TEXT NOT NULL PRIMARY KEY,
          value TEXT)"
        metadata_table_was_created = true
      end

      prepare_method :set_metadata_query, "INSERT INTO metadata (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value=excluded.value"
      prepare_method :get_metadata_query, "SELECT value FROM metadata WHERE key = ?"

      set_metadata("metadata_table_created_by_gem_version", FileDigests::VERSION) if FileDigests::VERSION && metadata_table_was_created

      # Heuristic to detect database version 1 (metadata was not stored back then)
      unless get_metadata("database_version")
        if table_exist?("digests")
          set_metadata "database_version", "1"
        end
      end

      unless table_exist?("digests")
        execute "CREATE TABLE digests (
          id INTEGER NOT NULL PRIMARY KEY,
          filename TEXT NOT NULL,
          mtime TEXT,
          digest TEXT NOT NULL)"
        execute "CREATE UNIQUE INDEX digests_filename ON digests(filename)"
        execute "CREATE INDEX digests_digest ON digests(digest)"
        set_metadata("digests_table_created_by_gem_version", FileDigests::VERSION) if FileDigests::VERSION
      end

      prepare_method :digests_insert, "INSERT INTO digests (filename, mtime, digest) VALUES (?, ?, ?)"
      prepare_method :digests_find_by_filename_query, "SELECT id, mtime, digest FROM digests WHERE filename = ?"
      prepare_method :digests_update_mtime_and_digest, "UPDATE digests SET mtime = ?, digest = ? WHERE id = ?"
      prepare_method :digests_update_mtime, "UPDATE digests SET mtime = ? WHERE id = ?"
      prepare_method :digests_select_duplicates, "SELECT digest, filename FROM digests WHERE digest IN (SELECT digest FROM digests GROUP BY digest HAVING count(*) > 1) ORDER BY digest, filename;"

      unless get_metadata("database_version")
        set_metadata "database_version", "4"
      end

      # Convert database from 1st to 2nd version
      unless get_metadata("digest_algorithm")
        if get_metadata("database_version") == "1"
          if File.exist?("#{File.dirname(@digest_database_path)}#{File::SEPARATOR}.file-digests.sha512")
            set_metadata("digest_algorithm", "SHA512")
          else
            set_metadata("digest_algorithm", "SHA256")
          end
          set_metadata "database_version", "2"
        end
      end

      if get_metadata("database_version") == "2"
        execute "CREATE INDEX digests_digest ON digests(digest)"
        set_metadata "database_version", "3"
      end

      if get_metadata("database_version") == "3"
        execute "ALTER TABLE digests DROP COLUMN digest_check_time"
        set_metadata "database_version", "4"
      end

      check_if_database_is_at_certain_version "4"

      create_temporary_tables
    end
  end

  def create_temporary_tables
    execute "CREATE TEMPORARY TABLE new_files (
      filename TEXT NOT NULL PRIMARY KEY,
      digest TEXT NOT NULL)"
    execute "CREATE INDEX new_files_digest ON new_files(digest)"

    prepare_method :new_files_insert, "INSERT INTO new_files (filename, digest) VALUES (?, ?)"
    prepare_method :new_files_count_query, "SELECT count(*) FROM new_files"

    execute "CREATE TEMPORARY TABLE missing_files (
      filename TEXT NOT NULL PRIMARY KEY,
      digest TEXT NOT NULL)"
    execute "CREATE INDEX missing_files_digest ON missing_files(digest)"

    execute "INSERT INTO missing_files (filename, digest) SELECT filename, digest FROM digests"

    prepare_method :missing_files_delete, "DELETE FROM missing_files WHERE filename = ?"
    prepare_method :missing_files_delete_renamed_files, "DELETE FROM missing_files WHERE digest IN (SELECT digest FROM new_files)"
    prepare_method :missing_files_select_all_filenames, "SELECT filename FROM missing_files ORDER BY filename"
    prepare_method :missing_files_delete_all, "DELETE FROM missing_files"
    prepare_method :missing_files_count_query, "SELECT count(*) FROM missing_files"

    prepare_method :digests_delete_renamed_files, "DELETE FROM digests WHERE filename IN (SELECT filename FROM missing_files WHERE digest IN (SELECT digest FROM new_files))"
    prepare_method :digests_delete_all_missing_files, "DELETE FROM digests WHERE filename IN (SELECT filename FROM missing_files)"

    execute "CREATE TEMPORARY TABLE new_digests (
      filename TEXT NOT NULL PRIMARY KEY,
      digest TEXT NOT NULL)"

    prepare_method :new_digests_insert, "INSERT INTO new_digests (filename, digest) VALUES (?, ?)"
    prepare_method :digests_update_digests_to_new_digests, "INSERT INTO digests (filename, digest) SELECT filename, digest FROM new_digests WHERE true ON CONFLICT (filename) DO UPDATE SET digest=excluded.digest"
  end

  # Files

  def realpath path
    realxpath path, :realpath
  end

  def realdirpath path
    realxpath path, :realdirpath
  end

  def realxpath path, method_name
    path = path.encode("utf-8")

    if Gem.win_platform?
      path = path.gsub(/\\/, "/")
    end

    path = File.send(method_name, path).encode("utf-8")

    if Gem.win_platform? && path[0] == "/"
      path = Dir.pwd[0, 2].encode("utf-8") + path
    end

    path
  end

  def perhaps_nt_path path
    if Gem.win_platform?
      "\\??\\#{path.gsub(/\//,"\\")}"
    else
      path
    end
  end

  def get_file_digest filename
    File.open(filename, "rb") do |io|
      digest = OpenSSL::Digest.new(@digest_algorithm)
      new_digest = OpenSSL::Digest.new(@new_digest_algorithm) if @new_digest_algorithm

      buffer = ""
      while io.read(409600, buffer) # 409600 seems like a sweet spot
        digest.update(buffer)
        new_digest.update(buffer) if @new_digest_algorithm
      end
      return [digest.hexdigest, (new_digest.hexdigest if @new_digest_algorithm)]
    end
  end

  def walk_files(path, &block)
    Dir.each_child(path, encoding: "UTF-8") do |item|
      item = "#{path}#{File::SEPARATOR}#{item.encode("utf-8")}"
      begin
        item_perhaps_nt_path = perhaps_nt_path item

        unless File.symlink? item_perhaps_nt_path
          if File.directory?(item_perhaps_nt_path)
            raise "Directory is not readable" unless File.readable?(item_perhaps_nt_path)
            walk_files(item, &block)
          else
            yield item
          end
        end

      rescue => exception
        @counters[:exceptions] += 1
        report_file_exception exception, item
      end
    end
  end

  def process_file filename
    perhaps_nt_filename = perhaps_nt_path filename

    # this is checked in the walk_files
    # return if File.symlink? perhaps_nt_filename

    stat = File.stat perhaps_nt_filename

    return if stat.blockdev?
    return if stat.chardev?
    return if stat.directory?
    return if stat.pipe?
    return if stat.socket?

    raise "File is not readable" unless stat.readable?

    if @skip_files.include?(filename)
      puts "SKIPPING FILE: #{filename}" if @options[:verbose]
      return
    end

    normalized_filename = filename.delete_prefix("#{@files_path}#{File::SEPARATOR}").encode("utf-8", universal_newline: true).unicode_normalize(:nfkc)
    mtime_string = time_to_database stat.mtime
    digest, new_digest = get_file_digest(perhaps_nt_filename)

    nested_transaction do
      new_digests_insert(normalized_filename, new_digest) if new_digest
      process_file_indeed normalized_filename, mtime_string, digest
    end
  end

  def process_file_indeed filename, mtime, digest
    if found = find_by_filename(filename)
      process_previously_seen_file found, filename, mtime, digest
    else
      process_new_file filename, mtime, digest
    end
  end

  def process_previously_seen_file found, filename, mtime, digest
    missing_files_delete filename
    if found["digest"] == digest
      @counters[:good] += 1
      puts "GOOD: #{filename}" if @options[:verbose]
      unless @options[:test_only]
        if found["mtime"] != mtime
          digests_update_mtime mtime, found["id"]
        end
      end
    else
      if found["mtime"] == mtime && !@options[:accept_fate] # Digest is different and mtime is the same
        @counters[:likely_damaged] += 1
        error_text "LIKELY DAMAGED: #{filename}"
      else
        @counters[:updated] += 1
        puts "UPDATED#{" (FATE ACCEPTED)" if found["mtime"] == mtime && @options[:accept_fate]}: #{filename}" unless @options[:quiet]
        unless @options[:test_only]
          digests_update_mtime_and_digest mtime, digest, found["id"]
        end
      end
    end
  end

  def process_new_file filename, mtime, digest
    puts "NEW: #{filename}" unless @options[:quiet]
    new_files_insert filename, digest
    unless @options[:test_only]
      digests_insert filename, mtime, digest
    end
  end


  # Renames and missing files

  def track_renames
    unless @options[:test_only]
      digests_delete_renamed_files
    end
    missing_files_delete_renamed_files
    @counters[:renamed] = @db.changes
  end

  def report_missing_files
    puts "\nMISSING FILES:"
    write_missing_files STDOUT
    if missing_files_count > 256
      File.open(@missing_files_path, "a") do |f|
        write_missing_files f
      end
      puts "\n(A list of missing files is also saved in a file: #{@missing_files_path})"
    end
  end

  def write_missing_files dest
    missing_files_select_all_filenames.each do |record|
      dest.puts record["filename"]
    end
  end

  def remove_missing_files
    digests_delete_all_missing_files
    missing_files_delete_all
  end

  def missing_files_count
    missing_files_count_query!&.first&.first
  end

  def any_missing_files?
    missing_files_count > 0
  end


  # Runtime state helpers

  def any_exceptions?
    @counters[:exceptions] > 0
  end

  def any_likely_damaged?
    @counters[:likely_damaged] > 0
  end


  # Database helpers

  def execute *args, &block
    @db.execute *args, &block
  end

  def integrity_check
    puts "Checking database integrity..." if @options[:verbose]
    if execute("PRAGMA integrity_check")&.first&.fetch("integrity_check") != "ok"
      raise "Database integrity check failed"
    end
  end

  def nested_transaction(mode = :deferred)
    if @db.transaction_active?
      yield
    else
      @db.transaction(mode) do
        yield
      end
    end
  end

  def perhaps_transaction(condition, mode = :deferred)
    if condition
      nested_transaction(mode) do
        yield
      end
    else
      yield
    end
  end

  def table_exist? table_name
    execute("SELECT name FROM sqlite_master WHERE type='table' AND name = ?", table_name).length == 1
  end

  def prepare_method name, query
    variable = "@#{name}"

    statement = @db.prepare(query)
    @statements.push(statement)

    instance_variable_set(variable, statement)

    define_singleton_method name do |*args, &block|
      instance_variable_get(variable).execute(*args, &block)
    end

    define_singleton_method "#{name}!" do |*args, &block|
      instance_variable_get(variable).execute!(*args, &block)
    end
  end

  def set_metadata key, value
    set_metadata_query key, value
    puts "#{key} set to: #{value}" if @options[:verbose]
    value
  end

  def get_metadata key
    get_metadata_query!(key)&.first&.first
  end

  def find_by_filename filename
    result = digests_find_by_filename_query filename
    found = result.next
    raise "Multiple records found" if result.next
    found
  end

  def time_to_database time
    time.utc.strftime("%Y-%m-%d %H:%M:%S")
  end

  def hide_database_files
    if Gem.win_platform?
      @digest_database_files.each do |file|
        if File.exist?(file)
          system "attrib", "+H", file, exception: true
        end
      end
    end
  end

  def check_if_database_is_at_certain_version target_version
    current_version = get_metadata("database_version")
    if current_version != target_version
      STDERR.puts "ERROR: This version of file-digests (#{FileDigests::VERSION || "unknown"}) is only compartible with the database version #{target_version}. Current database version is #{current_version}. To use this database, please install appropriate version if file-digest."
      raise "Incompatible database version"
    end
  end

  def new_files_count
    new_files_count_query!&.first&.first
  end


  # UI helpers

  def confirm text
    if STDIN.tty? && STDOUT.tty?
      puts "#{text} (y/n)?"
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = (STDIN.gets.strip.downcase == "y")
      @user_input_wait_time += (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start)
      result
    end
  end

  def measure_time
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) - @user_input_wait_time
    puts "Elapsed time: #{elapsed.to_i / 3600}h #{(elapsed.to_i % 3600) / 60}m #{"%.3f" % (elapsed % 60)}s" unless @options[:quiet]
  end

  def report_file_exception exception, filename
    write_file_exception STDERR, exception, filename
    File.open(@error_log_path, "a") do |f|
      write_file_exception f, exception, filename
    end
  end

  def write_file_exception dest, exception, filename
    dest.print "ERROR: #{exception.message}, processing file: "
    begin
      dest.print filename.encode("utf-8", universal_newline: true)
    rescue
      dest.print "(Unable to encode file name to utf-8) "
      dest.print filename
    end
    dest.print "\n"
    dest.flush
    exception.backtrace.each { |line| dest.puts "  " + line }
  end

  def error_text text
    STDERR.puts text
    File.open(@error_log_path, "a") do |f|
      f.puts text
    end
  end

  def print_counters
    missing_files_count_result = missing_files_count
    new_files_count_result = new_files_count - @counters[:renamed]

    puts "#{@counters[:good]} file(s) passes digest check" if @counters[:good] > 0
    puts "#{@counters[:updated]} file(s) are updated" if @counters[:updated] > 0
    puts "#{new_files_count_result} file(s) are new" if new_files_count_result > 0
    puts "#{@counters[:renamed]} file(s) are renamed" if @counters[:renamed] > 0
    puts "#{missing_files_count_result} file(s) are missing" if missing_files_count_result > 0
    puts "#{@counters[:likely_damaged]} file(s) are likely damaged (!)" if @counters[:likely_damaged] > 0
    puts "#{@counters[:exceptions]} file(s) had exceptions occured during processing (!)" if @counters[:exceptions] > 0
  end
end
