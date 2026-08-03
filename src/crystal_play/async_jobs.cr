require "json"

module CrystalPlay
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
    # half-written file.
    def self.write_status(jid : String, data : JSON::Any)
      Dir.mkdir_p(DIR)
      path = status_path(jid)
      tmp = "#{path}.tmp"
      File.write(tmp, data.to_json)
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
  end
end
