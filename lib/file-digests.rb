
require 'date'
require 'set'
require 'digest'
require 'fileutils'
require 'pathname'
require 'sqlite3'

module FileDigests

  def self.ensure_dir_exists path
    if File.exist?(path)
      unless File.directory?(path)
        raise "#{path} is not a directory"
      end
    else
      FileUtils.mkdir_p path
    end
  end

  def self.measure_time
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).to_i
    puts "Elapsed time: #{elapsed / 3600}h #{(elapsed % 3600) / 60}m #{elapsed % 60}s" unless QUIET
  end

  def self.patch_path_string path
    Gem.win_platform? ? path.gsub(/\\/, '/') : path
  end

  def self.perform_check
    files_path = Pathname.new patch_path_string(ARGV[0] || ".")
    digest_database_path = Pathname.new patch_path_string(ARGV[1]) if ARGV[1]
    checker = Checker.new files_path, digest_database_path
    checker.check
  end

  class DigestDatabase
    def initialize path
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

      @missing_files = Hash[@db.prepare("SELECT filename, digest FROM digests").execute!]
      @new_files = {}

      prepare_method :insert, "INSERT INTO digests (filename, mtime, digest, digest_check_time) VALUES (?, ?, ?, datetime('now'))"
      prepare_method :find_by_filename, "SELECT id, mtime, digest FROM digests WHERE filename = ?"
      prepare_method :touch_digest_check_time, "UPDATE digests SET digest_check_time = datetime('now') WHERE id = ?"
      prepare_method :update_mtime_and_digest, "UPDATE digests SET mtime = ?, digest = ?, digest_check_time = datetime('now') WHERE id = ?"
      prepare_method :update_mtime, "UPDATE digests SET mtime = ?, digest_check_time = datetime('now') WHERE id = ?"
      prepare_method :delete_by_filename, "DELETE FROM digests WHERE filename = ?"
    end

    def insert_or_update file_path, mtime, digest, counters
      result = find_by_filename file_path

      if found = result.next_hash
        raise "Multiple records found" if result.next

        @missing_files.delete(file_path)

        if found['digest'] == digest
          counters[:good] += 1
          # puts "GOOD: #{file_path}" unless QUIET
          unless TEST_ONLY
            if found['mtime'] == mtime
              touch_digest_check_time found['id']
            else
              update_mtime mtime, found['id']
            end
          end
        else
          if found['mtime'] == mtime # Digest is different and mtime is the same
            counters[:likely_damaged] += 1
            STDERR.puts "LIKELY DAMAGED: #{file_path}"
          else
            counters[:updated] += 1
            puts "UPDATED: #{file_path}" unless QUIET
            unless TEST_ONLY
              update_mtime_and_digest mtime, digest, found['id']
            end
          end
        end
      else
        counters[:new] += 1
        puts "NEW: #{file_path}" unless QUIET
        unless TEST_ONLY
          @new_files[file_path] = digest
          insert file_path, mtime, digest
        end
      end
    end

    def process_missing_files counters
      @missing_files.delete_if do |filename, digest|
        if @new_files.value?(digest)
          counters[:renamed] += 1
          unless TEST_ONLY
            delete_by_filename filename
          end
          true
        end
      end

      if (counters[:missing] = @missing_files.length) > 0
        puts "\nMISSING FILES:"
        @missing_files.sort.to_h.each do |filename, digest|
          puts filename
        end
        unless TEST_ONLY
          puts "Remove missing files from the database (y/n)?"
          if STDIN.gets.strip.downcase == "y"
            @db.transaction do
              @missing_files.each do |filename, digest|
                delete_by_filename filename
              end
            end
          end
        end
      end
    end

    private

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

  class Checker
    def initialize files_path, digest_database_path
      @counters = {good: 0, updated: 0, new: 0, missing: 0, renamed: 0, likely_damaged: 0, exceptions: 0}
      @files_path = files_path
      @prefix_to_remove = @files_path.to_s + '/'

      unless digest_database_path
        digest_database_path = @files_path + '.file-digests.sqlite'
        @skip_file_digests_sqlite = true
      end

      FileDigests::ensure_dir_exists @files_path
      FileDigests::ensure_dir_exists digest_database_path.dirname

      @digest_database = DigestDatabase.new digest_database_path
    end

    def check
      FileDigests::measure_time do
        walk_files do |filename|
          process_file filename
        end
      end

      @digest_database.process_missing_files @counters

      if @counters[:likely_damaged] > 0 || @counters[:exceptions] > 0
        STDERR.puts "ERRORS WERE OCCURRED"
      end

      puts @counters.inspect
    end

    def walk_files
      Dir.glob(@files_path + '**' + '*', File::FNM_DOTMATCH) do |filename|
        yield filename
      end
    end

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
        return if filename == '.file-digests.sqlite'
        return if filename == '.file-digests.sqlite-wal'
        return if filename == '.file-digests.sqlite-shm'
      end

      @digest_database.insert_or_update(
        filename.delete_prefix(@prefix_to_remove).unicode_normalize(:nfkc),
        stat.mtime.utc.strftime('%Y-%m-%d %H:%M:%S'),
        get_file_digest(filename),
        @counters
        )
    rescue => exception
      @counters[:exceptions] += 1
      STDERR.puts "EXCEPTION: #{filename}: #{exception.message}"
    end

    def get_file_digest filename
      File.open(filename, 'rb') do |io|
        digest = Digest::SHA512.new
        buffer = ""
        while io.read(40960, buffer)
          digest.update(buffer)
        end
        return digest.hexdigest
      end
    end

  end
end
