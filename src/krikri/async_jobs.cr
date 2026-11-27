require "json"

module Krikri
  # AsyncJobs - shared job-status-file conventions for async:/poll:/
  # async_status:. A background job (spawned as a separate, detached OS
  # process by TaskExecutor#execute_async, not a Fiber - so it keeps
  # running even if it outlives the poll loop or the whole playbook run)
  # writes its result here; async_status: (plugins/async_status.cr) reads
  # it back. Mirrors Ansible's own ~/.ansible_async/<jid> convention. The
  # local path resolves the dir on this controller; the remote path (ssh
  # and aws_ssm) resolves ~ on the target and reports the absolute path
  # back as results_file.
  module AsyncJobs
    class InvalidJidError < Exception; end

    # Jids are joined into file paths under the async dir, so anything
    # that isn't a bare, simple job-id-shaped token (generate_jid's and
    # Ansible's own "j<digits>.<digits>" shape - Ansible builds it as
    # j<random> in the action plugin and appends ".<pid>" in
    # async_wrapper - printed verbatim in its ASYNC POLL/OK lines and
    # stored as the registered ansible_job_id, so we match it for output
    # parity; or a lookup probe like
    # "no-such-job-...") is rejected before it can carry "/" or ".." into
    # the join - a traversal jid would otherwise let an async_status task
    # read (status mode) or delete (mode: cleanup) an arbitrary
    # controller-local file.
    JID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

    def self.valid_jid?(jid : String) : Bool
      !jid.empty? && JID_PATTERN.matches?(jid)
    end

    # The controller-local async dir, resolved at call time (not require
    # time) so tests and concurrent processes can redirect it: env
    # ANSIBLE_ASYNC_DIR when set (the shell plugin's `async_dir` option;
    # Ansible's own env name and default ~/.ansible_async, confirmed
    # via `ansible-doc -t shell sh`), else the HOME default. A leading ~
    # in the configured value is expanded against HOME.
    def self.dir : String
      if configured = ENV["ANSIBLE_ASYNC_DIR"]?
        return expand_home(configured) unless configured.empty?
      end
      File.join(ENV["HOME"]? || "/tmp", ".ansible_async")
    end

    private def self.expand_home(path : String) : String
      return path unless path.starts_with?('~')
      home = ENV["HOME"]?
      return path if home.nil? || home.empty?
      return home if path == "~"
      return File.join(home, path.lchop("~/")) if path.starts_with?("~/")
      path
    end

    def self.status_path(jid : String) : String
      raise InvalidJidError.new("invalid jid: #{jid}") unless valid_jid?(jid)
      File.join(dir, jid)
    end

    def self.config_path(jid : String) : String
      raise InvalidJidError.new("invalid jid: #{jid}") unless valid_jid?(jid)
      File.join(dir, "#{jid}.config.json")
    end

    # Atomic (write-then-rename) so a concurrent reader never sees a
    # half-written file. Written 0600 - status payloads can carry module
    # output, and the dir path is predictable.
    def self.write_status(jid : String, data : JSON::Any) : Nil
      Dir.mkdir_p(dir)
      path = status_path(jid)
      tmp = "#{path}.tmp"
      # chmod BEFORE writing: a chmod-after-write leaves the tmp file
      # 0644 (umask-dependent) while it already holds the payload.
      File.open(tmp, "w") do |io|
        io.chmod(0o600)
        io.write(data.to_json.to_slice)
      end
      File.rename(tmp, path)
    end

    # Config counterpart to write_status: the full module params the
    # background process will execute. Unlike the status file there's no
    # concurrent reader, so no tmp+rename - but the same 0600-at-creation
    # rule applies, and more so: this payload IS the params, secrets
    # included. chmod BEFORE writing so the file never exists with the
    # payload at umask-default perms.
    def self.write_config(jid : String, data : String) : Nil
      Dir.mkdir_p(dir)
      File.open(config_path(jid), "w") do |file|
        file.chmod(0o600)
        file.write(data.to_slice)
      end
    end

    def self.read_status(jid : String) : JSON::Any?
      path = status_path(jid)
      return nil unless File.exists?(path)
      JSON.parse(File.read(path))
    rescue
      nil
    end

    # What ansible-core's async_wrapper leaves in the job file when a job
    # outlives its async: budget: it SIGKILLs the module's whole process
    # group and then writes this record, so a later async_status: (or the
    # poll loop's final read) reports the timeout instead of a missing or
    # still-starting job. Live-verified against 2.21.6: the
    # ~/.ansible_async file an un-polled `async: 1, poll: 0` job leaves on
    # the target holds exactly {"msg": "Timeout exceeded", "failed": true,
    # "child_pid": <module pid>}. Both execution paths write it through
    # here so the payload can never drift between them.
    def self.timeout_record(child_pid : Int64) : JSON::Any
      JSON.parse({
        "msg"       => "Timeout exceeded",
        "failed"    => true,
        "child_pid" => child_pid,
      }.to_json)
    end

    # Ansible's async jid is "j<random digits>.<pid>" (action plugin
    # makes j<random>, async_wrapper appends the pid), and that exact
    # string shows up in the ASYNC POLL/OK output lines and as the
    # registered ansible_job_id - so generate_jid follows the same
    # shape for byte-level output parity. Random::Secure keeps it
    # unpredictable like Ansible's secrets.randbelow.
    def self.generate_jid : String
      "j#{Random::Secure.rand(999_999_999_999_i64)}.#{Random::Secure.rand(1..4_194_304)}"
    end

    def self.finished?(status : JSON::Any) : Bool
      # The remote async launch runs the module binary directly and
      # collects its stdout into the status file via tmp+mv - the file's
      # APPEARANCE is the completion signal, so a status WITHOUT a
      # "finished" key is the FINAL module result (Ansible's own
      # async_wrapper writes started/finished around the module result;
      # the mv'd module output legitimately carries no such key). Only
      # the explicit stub ({"started": 1, "finished": 0, ...} written
      # synchronously at launch) means "still running". Before the stub
      # existed, "file absent" meant running and this key check was the
      # only signal; now: explicit 0 = running, absent or 1 = finished.
      case finished = status["finished"]?.try(&.raw)
      when Nil   then true
      when Int64 then finished == 1
      when Bool  then finished
      else            true
      end
    end

    # Deletes one job's status, config and launch sidecar files
    # (`async_status: mode: cleanup` for a single jid). The remote launch
    # owns four paths beside each other: the status file, the args file
    # (<jid>.config.json), a become-password wrapper (<jid>.run) and a
    # transient result (<jid>.tmp); all four are removed so a play that
    # cleanups its jobs leaves nothing behind. Cleanup is meant for a
    # finished or abandoned job: removing <jid>.tmp under a still-running
    # worker drops that job's result rather than keeping it. Returns true
    # when anything was removed.
    def self.cleanup(jid : String) : Bool
      removed = false
      status = status_path(jid)
      [status, config_path(jid), "#{status}.run", "#{status}.tmp"].each do |path|
        next unless File.exists?(path)
        begin
          File.delete(path)
          removed = true
        rescue File::Error
          # Vanished between the exists? check and the delete - counts
          # as cleaned up either way.
        end
      end
      removed
    end

    # Removes every job file in the async dir - Ansible's
    # async_status mode=cleanup with jid: ALL. ~/.ansible_async
    # previously grew without bound for the lifetime of the account.
    # Stray .tmp leftovers from a crashed write are swept too. Returns
    # the number of files removed.
    def self.cleanup_all : Int32
      dir = self.dir
      return 0 unless Dir.exists?(dir)
      removed = 0
      Dir.each_child(dir) do |name|
        File.delete(File.join(dir, name))
        removed += 1
      rescue File::Error
        # A concurrent job's transient file - leave it.
      end
      removed
    end
  end
end
