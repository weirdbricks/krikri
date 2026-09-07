require "json"

module Krikri
  # AsyncJobs - shared job-status-file conventions for async:/poll:/
  # async_status:. A background job (spawned as a separate, detached OS
  # process by TaskExecutor#execute_async, not a Fiber - so it keeps
  # running even if it outlives the poll loop or the whole playbook run)
  # writes its result here; async_status: (plugins/async_status.cr) reads
  # it back. Mirrors real Ansible's own ~/.ansible_async/<jid> convention,
  # though only for local connections - see execute_async's own comment
  # for why remote async isn't implemented.
  module AsyncJobs
    DIR = File.join(ENV["HOME"]? || "/tmp", ".ansible_async")

    def self.status_path(jid : String) : String
      File.join(DIR, jid)
    end

    def self.config_path(jid : String) : String
      File.join(DIR, "#{jid}.config.json")
    end

    # Atomic (write-then-rename) so a concurrent reader never sees a
    # half-written file. Written 0600 - status payloads can carry module
    # output, and the DIR path is predictable.
    def self.write_status(jid : String, data : JSON::Any) : Nil
      Dir.mkdir_p(DIR)
      path = status_path(jid)
      tmp = "#{path}.tmp"
      File.write(tmp, data.to_json)
      File.chmod(tmp, 0o600)
      File.rename(tmp, path)
    end

    def self.read_status(jid : String) : JSON::Any?
      path = status_path(jid)
      return nil unless File.exists?(path)
      JSON.parse(File.read(path))
    rescue
      nil
    end

    def self.generate_jid : String
      "#{Time.utc.to_unix}.#{Random::Secure.hex(6)}"
    end

    def self.finished?(status : JSON::Any) : Bool
      status["finished"]?.try(&.as_i?) == 1
    end

    # Deletes one job's status + config files (real Ansible's own
    # async_status mode=cleanup for a single jid). Returns true when
    # anything was removed.
    def self.cleanup(jid : String) : Bool
      removed = false
      [status_path(jid), config_path(jid)].each do |path|
        next unless File.exists?(path)
        begin
          File.delete(path)
          removed = true
        rescue ex : File::Error
          # Vanished between the exists? check and the delete - counts
          # as cleaned up either way.
        end
      end
      removed
    end

    # Removes every job file in the async dir - real Ansible's
    # async_status mode=cleanup with jid: ALL. ~/.ansible_async
    # previously grew without bound for the lifetime of the account.
    # Stray .tmp leftovers from a crashed write are swept too. Returns
    # the number of files removed.
    def self.cleanup_all : Int32
      return 0 unless Dir.exists?(DIR)
      removed = 0
      Dir.each_child(DIR) do |name|
        File.delete(File.join(DIR, name))
        removed += 1
      rescue ex : File::Error
        # A concurrent job's transient file - leave it.
      end
      removed
    end
  end
end
