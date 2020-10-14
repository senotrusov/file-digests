require 'date'
require 'digest'
require 'fileutils'
require 'openssl'
require 'optparse'
require 'pathname'
require 'set'
require 'sqlite3'

class FileDigests
  DIGEST_ALGORITHMS=["BLAKE2b512", "SHA3-256", "SHA512-256"]
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

      opts.on("-a", "--auto", "Do not ask for any confirmation") do
        options[:auto] = true
      end

      opts.on("--accept-fate", "Accept the current state of files that are likely damaged and update their digest data") do
        options[:accept_fate] = true
      end

      opts.on(
        '--digest=DIGEST',
        'Select a digest algorithm to use. Default is "BLAKE2b512".',
        'You might also consider to use slower "SHA512-256" or even more slower "SHA3-256".',
        "#{digest_algorithms_list_text}.",
        'You only need to specify an algorithm on the first run, your choice will be saved to a database.',
        'Any time later you could specify a new algorithm to change the current one.',
        'Transition to a new algorithm will only occur if all files pass the check by digests which were stored using the old one.'
      ) do |value|
        digest_algorithm = canonical_digest_algorithm_name(value)
        unless DIGEST_ALGORITHMS.include?(digest_algorithm)
          STDERR.puts "ERROR: #{digest_algorithms_list_text}"
          exit 1
        end
        options[:digest_algorithm] = digest_algorithm
      end

      opts.on("-d", "--duplicates", "Show the list of duplicate files, based on the information out of the database") do
        options[:action] = :show_duplicates
      end

      opts.on("-t", "--test", "Perform only the test, do not modify the digest database") do
        options[:test_only] = true
      end

      opts.on("-q", "--quiet", "Less verbose output, stil report any found issues") do
        options[:quiet] = true
      end

      opts.on("-v", "--verbose", "More verbose output") do
        options[:verbose] = true
      end

      opts.on("-h", "--help", "Prints this help") do
        puts opts
        exit
      end
    end.parse!
    options
  end

  def self.run_cli_utility
    options = parse_cli_options

    file_digests = self.new ARGV[0], ARGV[1], options
    file_digests.send(options[:action] || :perform_check)
  end

  def initialize files_path, digest_database_path, options = {}
    @options = options

    initialize_paths files_path, digest_database_path
    initialize_database

    if @digest_algorithm = canonical_digest_algorithm_name(get_metadata("digest_algorithm"))
      if @options[:digest_algorithm] && @options[:digest_algorithm] != @digest_algorithm
        @new_digest_algorithm = @options[:digest_algorithm]
      end
    else
      @digest_algorithm = (@options[:digest_algorithm] || "BLAKE2b512")
      set_metadata "digest_algorithm", @digest_algorithm
    end

    puts "Using #{@digest_algorithm} digest algorithm" if @options[:verbose]
  end

  def initialize_paths files_path, digest_database_path
    @files_path = cleanup_path(files_path || ".")

    raise "Files path must be a readable directory" unless (File.directory?(@files_path) && File.readable?(@files_path))

    @digest_database_path = digest_database_path ? cleanup_path(digest_database_path) : @files_path
    @digest_database_path += '.file-digests.sqlite' if File.directory?(@digest_database_path)
    ensure_dir_exists @digest_database_path.dirname

    if @options[:verbose]
      puts "Target directory: #{@files_path}"
      puts "Database location: #{@digest_database_path}"
    end
  end

  def initialize_database
    @db = SQLite3::Database.new @digest_database_path.to_s
    @db.results_as_hash = true

    file_digests_gem_version = Gem.loaded_specs["file-digests"]&.version&.to_s

    execute 'PRAGMA encoding = "UTF-8"'
    execute 'PRAGMA journal_mode = "WAL"'
    execute 'PRAGMA synchronous = "NORMAL"'
    execute 'PRAGMA locking_mode = "EXCLUSIVE"'
    execute 'PRAGMA cache_size = "5000"'

    @db.transaction(:exclusive) do
      metadata_table_was_created = false
      unless table_exist?("metadata")
        execute "CREATE TABLE metadata (
          key TEXT NOT NULL PRIMARY KEY,
          value TEXT)"
        execute "CREATE UNIQUE INDEX metadata_key ON metadata(key)"
        metadata_table_was_created = true
      end

      prepare_method :set_metadata_query, "INSERT INTO metadata (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value=excluded.value"
      prepare_method :get_metadata_query, "SELECT value FROM metadata WHERE key = ?"

      set_metadata("metadata_table_created_by_gem_version", file_digests_gem_version) if file_digests_gem_version && metadata_table_was_created

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
          digest TEXT NOT NULL,
          digest_check_time TEXT NOT NULL)"
        execute "CREATE UNIQUE INDEX digests_filename ON digests(filename)"
        set_metadata("digests_table_created_by_gem_version", file_digests_gem_version) if file_digests_gem_version
      end

      prepare_method :insert, "INSERT INTO digests (filename, mtime, digest, digest_check_time) VALUES (?, ?, ?, datetime('now'))"
      prepare_method :find_by_filename_query, "SELECT id, mtime, digest FROM digests WHERE filename = ?"
      prepare_method :touch_digest_check_time, "UPDATE digests SET digest_check_time = datetime('now') WHERE id = ?"
      prepare_method :update_mtime_and_digest, "UPDATE digests SET mtime = ?, digest = ?, digest_check_time = datetime('now') WHERE id = ?"
      prepare_method :update_mtime, "UPDATE digests SET mtime = ?, digest_check_time = datetime('now') WHERE id = ?"
      prepare_method :delete_by_filename, "DELETE FROM digests WHERE filename = ?"
      prepare_method :query_duplicates, "SELECT digest, filename FROM digests WHERE digest IN (SELECT digest FROM digests GROUP BY digest HAVING count(*) > 1) ORDER BY digest, filename;"
      prepare_method :update_digest_to_new_digest, "UPDATE digests SET digest = ? WHERE digest = ?"

      unless get_metadata("database_version")
        set_metadata "database_version", "2"
      end

      # Convert database from 1st to 2nd version
      unless get_metadata("digest_algorithm")
        if get_metadata("database_version") == "1"
          if File.exist?(@digest_database_path.dirname + '.file-digests.sha512')
            set_metadata("digest_algorithm", "SHA512")
          else
            set_metadata("digest_algorithm", "SHA256")
          end
          set_metadata "database_version", "2"
        end
      end

      if get_metadata("database_version") != "2"
        STDERR.puts "This version of file-digests (#{file_digests_gem_version || 'unknown'}) is only compartible with the database version 2. Current database version is #{get_metadata("database_version")}. To use this database, please install appropriate version if file-digest."
        raise "Incompatible database version"
      end
    end
  end

  def perform_check
    perhaps_transaction(@new_digest_algorithm, :exclusive) do
      @counters = {good: 0, updated: 0, new: 0, renamed: 0, likely_damaged: 0, exceptions: 0}
      @new_files = {}
      @new_digests = {}

      @missing_files = Hash[@db.prepare("SELECT filename, digest FROM digests").execute!]

      measure_time do
        walk_files do |filename|
          process_file filename
        end
      end

      track_renames

      if any_missing_files?
        if any_exceptions?
          STDERR.puts "Due to previously occurred errors, database cleanup from missing files will be skipped this time."
        else
          print_missing_files
          if !@options[:test_only] && (@options[:auto] || confirm("Remove missing files from the database"))
            remove_missing_files
          end
        end
      end

      if @new_digest_algorithm && !@options[:test_only]
        if any_missing_files? || any_likely_damaged? || any_exceptions?
          STDERR.puts "ERROR: New digest algorithm will not be in effect until there are files that are missing, likely damaged, or processed with an exception."
        else
          @new_digests.each do |old_digest, new_digest|
            update_digest_to_new_digest new_digest, old_digest
          end
          set_metadata "digest_algorithm", @new_digest_algorithm
          puts "Transition to a new digest algorithm complete: #{@new_digest_algorithm}"
        end
      end

      if any_likely_damaged? || any_exceptions?
        STDERR.puts "PLEASE REVIEW ERRORS THAT WERE OCCURRED!"
      end

      set_metadata(@options[:test_only] ? "latest_test_only_check_time" : "latest_complete_check_time", time_to_database(Time.now))

      print_counters
    end
  end

  def show_duplicates
    current_digest = nil
    query_duplicates.each do |found|
      if current_digest != found['digest']
        puts "" if current_digest
        current_digest = found['digest']
        puts "#{found['digest']}:"
      end
      puts "  #{found['filename']}"
    end
  end

  private

  def process_file filename
    return if File.symlink? filename

    stat = File.stat filename

    return if stat.blockdev?
    return if stat.chardev?
    return if stat.directory?
    return if stat.pipe?
    return if stat.socket?

    raise "File is not readable" unless stat.readable?

    if filename == "#{@digest_database_path}" ||
       filename == "#{@digest_database_path}-wal" ||
       filename == "#{@digest_database_path}-shm"
      puts "SKIPPING DATABASE FILE: #{filename}" if @options[:verbose]
      return
    end

    normalized_filename = filename.delete_prefix("#{@files_path.to_s}/").encode('utf-8', universal_newline: true).unicode_normalize(:nfkc)
    mtime_string = time_to_database stat.mtime

    process_file_indeed normalized_filename, mtime_string, get_file_digest(filename)

  rescue => exception
    @counters[:exceptions] += 1
    print_file_exception exception, filename
  end

  def process_file_indeed filename, mtime, digest
    if found = find_by_filename(filename)
      process_previously_seen_file found, filename, mtime, digest
    else
      process_new_file filename, mtime, digest
    end
  end

  def process_previously_seen_file found, filename, mtime, digest
    @missing_files.delete(filename)
    if found['digest'] == digest
      @counters[:good] += 1
      puts "GOOD: #{filename}" if @options[:verbose]
      unless @options[:test_only]
        if found['mtime'] == mtime
          touch_digest_check_time found['id']
        else
          update_mtime mtime, found['id']
        end
      end
    else
      if found['mtime'] == mtime && !@options[:accept_fate] # Digest is different and mtime is the same
        @counters[:likely_damaged] += 1
        STDERR.puts "LIKELY DAMAGED: #{filename}"
      else
        @counters[:updated] += 1
        puts "UPDATED: #{filename}" unless @options[:quiet]
        unless @options[:test_only]
          update_mtime_and_digest mtime, digest, found['id']
        end
      end
    end
  end

  def process_new_file filename, mtime, digest
    @counters[:new] += 1
    puts "NEW: #{filename}" unless @options[:quiet]
    unless @options[:test_only]
      @new_files[filename] = digest
      insert filename, mtime, digest
    end
  end


  # Renames and missing files

  def track_renames
    @missing_files.delete_if do |filename, digest|
      if @new_files.value?(digest)
        @counters[:renamed] += 1
        unless @options[:test_only]
          delete_by_filename filename
        end
        true
      end
    end
  end

  def print_missing_files
    puts "\nMISSING FILES:"
    @missing_files.sort.to_h.each do |filename, digest|
      puts filename
    end
  end

  def remove_missing_files
    nested_transaction do
      @missing_files.each do |filename, digest|
        delete_by_filename filename
      end
      @missing_files = {}
    end
  end


  # Database helpers

  def execute *args, &block
    @db.execute *args, &block
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
    execute("SELECT name FROM sqlite_master WHERE type='table' AND name = '#{table_name}'").length == 1
  end

  def prepare_method name, query
    variable = "@#{name}"

    instance_variable_set(variable, @db.prepare(query))

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
    result = find_by_filename_query filename
    found = result.next
    raise "Multiple records found" if result.next
    found
  end

  def time_to_database time
    time.utc.strftime('%Y-%m-%d %H:%M:%S')
  end


  # Filesystem-related helpers

  def patch_path_string path
    Gem.win_platform? ? path.gsub(/\\/, '/') : path
  end

  def cleanup_path path
    Pathname.new(patch_path_string(path)).cleanpath
  end

  def ensure_dir_exists path
    if File.exist?(path)
      unless File.directory?(path)
        raise "#{path} is not a directory"
      end
    else
      FileUtils.mkdir_p path
    end
  end

  def walk_files
    Dir.glob(@files_path + '**' + '*', File::FNM_DOTMATCH) do |filename|
      yield filename
    end
  end

  def get_file_digest filename
    File.open(filename, 'rb') do |io|
      digest = OpenSSL::Digest.new(@digest_algorithm)
      new_digest = OpenSSL::Digest.new(@new_digest_algorithm) if @new_digest_algorithm

      buffer = ""
      while io.read(409600, buffer) # 409600 seems like a sweet spot
        digest.update(buffer)
        new_digest.update(buffer) if @new_digest_algorithm
      end
      @new_digests[digest.hexdigest] = new_digest.hexdigest if @new_digest_algorithm
      return digest.hexdigest
    end
  end


  # Runtime state helpers

  def any_missing_files?
    @missing_files.length > 0
  end

  def any_exceptions?
    @counters[:exceptions] > 0
  end

  def any_likely_damaged?
    @counters[:likely_damaged] > 0
  end

  # UI helpers

  def confirm text
    if STDIN.tty? && STDOUT.tty?
      puts "#{text} (y/n)?"
      STDIN.gets.strip.downcase == "y"
    end
  end

  def measure_time
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start)
    puts "Elapsed time: #{elapsed.to_i / 3600}h #{(elapsed.to_i % 3600) / 60}m #{'%.3f' % (elapsed % 60)}s" unless @options[:quiet]
  end

  def print_file_exception exception, filename
    STDERR.print "EXCEPTION: #{exception.message}, processing file: "
    begin
      STDERR.print filename.encode('utf-8', universal_newline: true)
    rescue
      STDERR.print "(Unable to encode file name to utf-8) "
      STDERR.print filename
    end
    STDERR.print "\n"
    STDERR.flush
    exception.backtrace.each { |line| STDERR.puts "  " + line }
  end

  def print_counters
    puts "#{@counters[:good]} file(s) passes digest check" if @counters[:good] > 0
    puts "#{@counters[:updated]} file(s) are updated" if @counters[:updated] > 0
    puts "#{@counters[:new]} file(s) are new" if @counters[:new] > 0
    puts "#{@counters[:renamed]} file(s) are renamed" if @counters[:renamed] > 0
    puts "#{@missing_files.length} file(s) are missing" if @missing_files.length > 0
    puts "#{@counters[:likely_damaged]} file(s) are likely damaged (!)" if @counters[:likely_damaged] > 0
    puts "#{@counters[:exceptions]} file(s) had exceptions occured during processing (!)" if @counters[:exceptions] > 0
  end
end
