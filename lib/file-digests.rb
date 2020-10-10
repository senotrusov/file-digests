require 'date'
require 'set'
require 'digest'
require 'fileutils'
require 'pathname'
require 'sqlite3'

class FileDigests

  def self.perform_check
    options = {
      auto: (ENV["AUTO"] == "true"),
      quiet: (ENV["QUIET"] == "true"),
      test_only: (ENV["TEST_ONLY"] == "true")
    }
    file_digests = self.new ARGV[0], ARGV[1], options
    file_digests.perform_check
  end

  def self.show_duplicates
    file_digests = self.new ARGV[0], ARGV[1]
    file_digests.show_duplicates
  end

  def initialize files_path, digest_database_path, options = {}
    @options = options

    @files_path = cleanup_path(files_path || ".")
    @prefix_to_remove = @files_path.to_s + '/'

    raise "Files path must be a readable directory" unless (File.directory?(@files_path) && File.readable?(@files_path))

    @digest_database_path = if digest_database_path
      cleanup_path(digest_database_path)
    else
      @files_path + '.file-digests.sqlite'
    end

    if File.directory?(@digest_database_path)
      @digest_database_path = @digest_database_path + '.file-digests.sqlite'
    end

    if @files_path == @digest_database_path.dirname
      @skip_file_digests_sqlite = true
    end

    ensure_dir_exists @digest_database_path.dirname

    # Please do not use this flag, support for sha512 is here for backward compatibility, and one day it will be removed.
    if File.exist?(@digest_database_path.dirname + '.file-digests.sha512')
      @use_sha512 = true
    end

    initialize_database @digest_database_path
  end

  def initialize_database path
    @db = SQLite3::Database.new path.to_s
    @db.results_as_hash = true

    execute 'PRAGMA journal_mode = "WAL"'
    execute 'PRAGMA synchronous = "NORMAL"'
    execute 'PRAGMA locking_mode = "EXCLUSIVE"'
    execute 'PRAGMA cache_size = "5000"'

    unless execute("SELECT name FROM sqlite_master WHERE type='table' AND name = 'digests'").length == 1
      execute 'PRAGMA encoding = "UTF-8"'
      execute "CREATE TABLE digests (
        id INTEGER PRIMARY KEY,
        filename TEXT,
        mtime TEXT,
        digest TEXT,
        digest_check_time TEXT)"
      execute "CREATE UNIQUE INDEX digests_filename ON digests(filename)"
    end

    prepare_method :insert, "INSERT INTO digests (filename, mtime, digest, digest_check_time) VALUES (?, ?, ?, datetime('now'))"
    prepare_method :find_by_filename, "SELECT id, mtime, digest FROM digests WHERE filename = ?"
    prepare_method :touch_digest_check_time, "UPDATE digests SET digest_check_time = datetime('now') WHERE id = ?"
    prepare_method :update_mtime_and_digest, "UPDATE digests SET mtime = ?, digest = ?, digest_check_time = datetime('now') WHERE id = ?"
    prepare_method :update_mtime, "UPDATE digests SET mtime = ?, digest_check_time = datetime('now') WHERE id = ?"
    prepare_method :delete_by_filename, "DELETE FROM digests WHERE filename = ?"
    prepare_method :query_duplicates, "SELECT digest, filename FROM digests WHERE digest IN (SELECT digest FROM digests GROUP BY digest HAVING count(*) > 1) ORDER BY digest, filename;"
  end

  def perform_check
    @counters = {good: 0, updated: 0, new: 0, missing: 0, renamed: 0, likely_damaged: 0, exceptions: 0}
    @missing_files = Hash[@db.prepare("SELECT filename, digest FROM digests").execute!]
    @new_files = {}

    measure_time do
      walk_files do |filename|
        process_file filename
      end
    end

    track_renames

    if any_missing_files?
      print_missing_files
      if !@options[:test_only] && (@options[:auto] || confirm("Remove missing files from the database"))
        remove_missing_files
      end
    end

    if @counters[:likely_damaged] > 0 || @counters[:exceptions] > 0
      STDERR.puts "ERRORS WERE OCCURRED"
    end

    puts @counters.inspect
  end

  def show_duplicates
    current_digest = nil
    result = query_duplicates

    while found = result.next_hash do
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
    unless stat.readable?
      raise "File is not readable"
    end
    return if stat.socket?

    if @skip_file_digests_sqlite
      basename = File.basename(filename)
      return if basename == '.file-digests.sha512'
      return if basename == '.file-digests.sqlite'
      return if basename == '.file-digests.sqlite-wal'
      return if basename == '.file-digests.sqlite-shm'
    end

    insert_or_update(
      filename.delete_prefix(@prefix_to_remove).encode('utf-8', universal_newline: true).unicode_normalize(:nfkc),
      stat.mtime.utc.strftime('%Y-%m-%d %H:%M:%S'),
      get_file_digest(filename)
      )
  rescue => exception
    @counters[:exceptions] += 1
    STDERR.puts "EXCEPTION: #{filename.encode('utf-8', universal_newline: true)}: #{exception.message}"
  end

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
      digest = (@use_sha512 ? Digest::SHA512 : Digest::SHA256).new
      buffer = ""
      while io.read(40960, buffer)
        digest.update(buffer)
      end
      return digest.hexdigest
    end
  end

  def confirm text
    if STDIN.tty? && STDOUT.tty?
      puts "#{text} (y/n)?"
      STDIN.gets.strip.downcase == "y"
    end
  end

  def measure_time
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).to_i
    puts "Elapsed time: #{elapsed / 3600}h #{(elapsed % 3600) / 60}m #{elapsed % 60}s" unless @options[:quiet]
  end

  def insert_or_update file_path, mtime, digest
    result = find_by_filename file_path

    if found = result.next_hash
      raise "Multiple records found" if result.next

      @missing_files.delete(file_path)

      if found['digest'] == digest
        @counters[:good] += 1
        # puts "GOOD: #{file_path}" unless @options[:quiet]
        unless @options[:test_only]
          if found['mtime'] == mtime
            touch_digest_check_time found['id']
          else
            update_mtime mtime, found['id']
          end
        end
      else
        if found['mtime'] == mtime # Digest is different and mtime is the same
          @counters[:likely_damaged] += 1
          STDERR.puts "LIKELY DAMAGED: #{file_path}"
        else
          @counters[:updated] += 1
          puts "UPDATED: #{file_path}" unless @options[:quiet]
          unless @options[:test_only]
            update_mtime_and_digest mtime, digest, found['id']
          end
        end
      end
    else
      @counters[:new] += 1
      puts "NEW: #{file_path}" unless @options[:quiet]
      unless @options[:test_only]
        @new_files[file_path] = digest
        insert file_path, mtime, digest
      end
    end
  end

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
    @counters[:missing] = @missing_files.length
  end

  def any_missing_files?
    @missing_files.length > 0
  end

  def print_missing_files
    puts "\nMISSING FILES:"
    @missing_files.sort.to_h.each do |filename, digest|
      puts filename
    end
  end

  def remove_missing_files
    @db.transaction do
      @missing_files.each do |filename, digest|
        delete_by_filename filename
      end
    end
  end

  def execute *args, &block
    @db.execute *args, &block
  end

  def prepare_method name, query
    variable = "@#{name}"
    instance_variable_set(variable, @db.prepare(query))
    define_singleton_method name do |*args, &block|
      instance_variable_get(variable).execute(*args, &block)
    end
  end
end
