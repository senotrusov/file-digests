require 'date'
require 'set'
require 'digest'
require 'fileutils'
require 'pathname'
require 'sqlite3'

def ensure_dir_exists path
  if File.exist?(path)
    unless File.directory?(path)
      STDERR.puts (error_string = "#{path} is not a directory")
      raise error_string
    end
  else
    FileUtils.mkdir_p path
  end
end

def measure_time
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).to_i
  puts "Elapsed time: #{elapsed / 3600}h #{(elapsed % 3600) / 60}m #{elapsed % 60}s" if VERBOSE
end

def patch_path_string path
  Gem.win_platform? ? path.gsub(/\\/, '/') : path
end

class DigestDatabase
  def initialize path
    @db = SQLite3::Database.new(path.to_s)

    unless @db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name = 'digests'").length == 1
      @db.execute 'PRAGMA encoding = "UTF-8"'
      @db.execute "CREATE TABLE digests (
        id INTEGER PRIMARY KEY,
        filename TEXT,
        mtime TEXT,
        digest TEXT,
        digest_check_time TEXT)"
      @db.execute "CREATE UNIQUE INDEX digests_filename ON digests(filename)"
    end

    @db.results_as_hash = true
    @missing_files = Hash[@db.prepare("SELECT filename, digest FROM digests").execute!]
    @new_files = {}


    @insert = @db.prepare("INSERT INTO digests (filename, mtime, digest, digest_check_time) VALUES (?, ?, ?, datetime('now'))")
    @find_by_filename = @db.prepare("SELECT id, mtime, digest FROM digests WHERE filename = ?")
    @touch_digest_check_time = @db.prepare("UPDATE digests SET digest_check_time = datetime('now') WHERE id = ?")
    @update_mtime_and_digest = @db.prepare("UPDATE digests SET mtime = ?, digest = ?, digest_check_time = datetime('now') WHERE id = ?")
    @delete_by_filename = @db.prepare("DELETE FROM digests WHERE filename = ?")
  end

  def insert_or_update file_path, mtime, digest
    result = @find_by_filename.execute file_path
    if found = result.next_hash
      raise "Multiple records found" if result.next

      @missing_files.delete(file_path)

      if found['mtime'] == mtime
        if found['digest'] == digest
          COUNTS[:good] += 1
          unless TEST_ONLY
            puts "GOOD: #{file_path}" if VERBOSE
            @touch_digest_check_time.execute found['id']
          end
        else
          COUNTS[:digest_is_different] += 1
          raise "Digest is different"
        end
      else
        COUNTS[:updated] += 1
        puts "UPDATED: #{file_path}" if VERBOSE
        unless TEST_ONLY
          @update_mtime_and_digest.execute mtime, digest, found['id']
        end
      end

    else
      COUNTS[:new] += 1
      puts "NEW: #{file_path}" if VERBOSE
      unless TEST_ONLY
        @new_files[file_path] = digest
        @insert.execute! file_path, mtime, digest
      end
    end

  end

  def process_missing_files
    @missing_files.delete_if do |filename, digest|
      if @new_files.value?(digest)
        COUNTS[:renamed] += 1
        unless TEST_ONLY
          @delete_by_filename.execute filename
        end
        true
      end
    end

    if (COUNTS[:missing] = @missing_files.length) > 0
      puts "MISSING FILES:"
      @missing_files.sort.to_h.each do |filename, digest|
        puts filename
      end
      unless TEST_ONLY
        puts "Remove missing files from the database (y/n)?"
        if STDIN.gets.strip == "y"
          @missing_files.each do |filename, digest|
            @delete_by_filename.execute filename
          end
        end
      end
    end
  end
end

class Checker
  def initialize files_path, digest_database_path
    @files_path = files_path
    @digest_database_path = digest_database_path

    ensure_dir_exists @files_path
    ensure_dir_exists @digest_database_path.dirname

    @digest_database = DigestDatabase.new @digest_database_path
  end

  def check
    walk_files do |filename|
      begin
        process_file filename
      rescue => exception
        STDERR.puts "#{filename}: #{exception.message}"
      end
    end

    @digest_database.process_missing_files
  end

  def walk_files
    Dir.glob(@files_path + '**' + '*') do |filename|
      next unless File.file? filename
      yield filename
    end
  end

  def process_file filename
    @digest_database.insert_or_update(
      filename.delete_prefix(@files_path.to_s + '/'),
      File.mtime(filename).utc.strftime('%Y-%m-%d %H:%M:%S'),
      get_file_digest(filename)
      )
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

VERBOSE = (ENV["VERBOSE"] == "true")
TEST_ONLY = (ENV["TEST_ONLY"] == "true")
COUNTS = {good: 0, updated: 0, new: 0, missing: 0, renamed: 0, digest_is_different: 0}

files_path = Pathname.new patch_path_string(ARGV[0])
digest_database_path = Pathname.new patch_path_string(ARGV[1])

measure_time do
  checker = Checker.new files_path, digest_database_path
  checker.check
end

puts COUNTS.inspect
