require "json"
require "digest/md5"
require "colorize"
require "./ssh_manager"
require "./local_executor"
require "./playbook_parser"
require "./inventory_parser"

module CrystalPlay
  # Plugin Manager - Handles plugin execution locally or remotely
  # For remote hosts, uploads plugin binary and executes it there
  class PluginManager
    # Cache of plugins already uploaded to remote hosts
    @@uploaded_plugins = Hash(String, Set(String)).new

    # Verbose mode flag
    @@verbose = false

    # Set verbose mode
    def self.verbose=(value : Bool)
      @@verbose = value
    end

    # Pre-upload all plugins needed for a playbook to all remote hosts
    # This is called once before task execution begins
    # Much more efficient than uploading plugins one at a time during execution
    def self.batch_upload_plugins_for_playbook(
      playbook : Playbook,
      inventory : Inventory,
    )
      # Collect all unique module names used in the playbook
      required_plugins = Set(String).new

      # Track if any play needs facts gathering
      needs_facts = false

      playbook.plays.each do |play|
        # Check if this play gathers facts
        needs_facts = true if play.gather_facts

        collect_required_plugins(play.tasks, required_plugins)

        play.handlers.each do |handler|
          simple_name = handler.module_name.sub(/^(ansible\.(builtin|legacy|posix)|community\.(general|docker|mysql|postgresql))\./, "")
          required_plugins.add(simple_name)
        end
      end

      # Add facts plugin if any play needs it
      required_plugins.add("facts") if needs_facts

      return if required_plugins.empty?

      # Collect all unique remote hosts from the playbook
      remote_hosts = [] of Host
      host_keys_seen = Set(String).new

      playbook.plays.each do |play|
        hosts = inventory.get_hosts(play.hosts.to_s)

        hosts.each do |host|
          # Skip localhost
          next if is_local_connection?(host, host.vars)

          # Deduplicate by connection details
          connection_host = get_connection_host(host, host.vars)
          host_key = "#{host.user}@#{connection_host}:#{host.port}"

          unless host_keys_seen.includes?(host_key)
            remote_hosts << host
            host_keys_seen.add(host_key)
          end
        end
      end

      return if remote_hosts.empty?

      puts "Preparing plugins for remote execution...".colorize(:cyan) if @@verbose

      # Upload plugins to each unique remote host
      remote_hosts.each do |host|
        upload_plugins_to_host(host, required_plugins.to_a)
      end

      puts "" if @@verbose
    end

    # Walks *tasks*, adding every real plugin module name to *required*,
    # recursing into block:/rescue:/always: nested lists so plugins used
    # only inside a block still get pre-uploaded. block?/include_tasks?/
    # include_role? tasks are pseudo-modules ("_block"/"_include_tasks"/
    # "_include_role") with no corresponding plugin binary - previously
    # added to the required set unconditionally, which crashed
    # get_local_plugin_path outright for any playbook with a block: task
    # targeting a real remote host (never caught before: every existing
    # block: fixture in this repo happens to run against a local
    # connection, which never reaches this code path at all).
    # include_tasks:/include_role: are deliberately not recursed into -
    # their contents are only known at runtime (the file/role may be
    # templated), so plugins used exclusively inside one aren't
    # pre-uploaded; a known, narrower limitation, not a regression from
    # this fix.
    private def self.collect_required_plugins(tasks : Array(Task), required : Set(String))
      tasks.each do |task|
        if task.block?
          collect_required_plugins(task.block_tasks || [] of Task, required)
          collect_required_plugins(task.rescue_tasks || [] of Task, required) if task.rescue_tasks
          collect_required_plugins(task.always_tasks || [] of Task, required) if task.always_tasks
          next
        end

        next if task.include_tasks? || task.include_role?

        simple_name = task.module_name.sub(/^(ansible\.(builtin|legacy|posix)|community\.(general|docker|mysql|postgresql))\./, "")
        required.add(simple_name)
      end
    end

    # Upload a set of plugins to a specific host.
    #
    # Collapsed to 3 SSH round trips total (was 2N+1): one to mkdir +
    # dump every existing remote .md5 in one pass, one rsync/scp transfer
    # for whatever needs uploading, one to write all the new .md5 files.
    private def self.upload_plugins_to_host(host : Host, plugin_names : Array(String))
      connection_host = get_connection_host(host, host.vars)
      host_key = "#{host.user}@#{connection_host}:#{host.port}"
      user = host.user || "root"

      # Initialize plugin cache for this host
      @@uploaded_plugins[host_key] ||= Set(String).new

      remote_plugin_dir = "/tmp/.crystal-play/plugins"

      candidates = plugin_names.reject { |name| @@uploaded_plugins[host_key].includes?(name) }
      return if candidates.empty?

      # Round trip 1: create the dir and dump every existing remote .md5
      # in one pass, so we don't need one `cat` per plugin to check it.
      list_script = <<-SCRIPT
        mkdir -p #{remote_plugin_dir}
        for f in #{remote_plugin_dir}/*.md5; do
          [ -f "$f" ] && echo "$(basename "$f" .md5) $(cat "$f")"
        done
        true
        SCRIPT
      remote_md5s = Hash(String, String).new
      SSHManager.exec_script(connection_host, user, list_script, host.port)[:stdout]
        .each_line do |line|
          name, _, md5 = line.strip.partition(' ')
          remote_md5s[name] = md5 unless name.empty?
        end

      # Local digest computed exactly once per plugin (streamed, not
      # loaded fully into memory), reused for both the compare and the
      # eventual .md5 write.
      local_paths = Hash(String, String).new
      local_md5s = Hash(String, String).new
      candidates.each do |plugin_name|
        path = get_local_plugin_path(plugin_name)
        local_paths[plugin_name] = path
        local_md5s[plugin_name] = Digest::MD5.new.file(path).hexfinal
      end

      plugins_to_upload = candidates.select do |plugin_name|
        remote_md5s[plugin_name]? != local_md5s[plugin_name]
      end
      (candidates - plugins_to_upload).each { |name| @@uploaded_plugins[host_key].add(name) }

      return if plugins_to_upload.empty?

      # Round trip 2: transfer whatever needs uploading.
      puts "   → Uploading #{plugins_to_upload.size} plugins to #{connection_host} via rsync".colorize(:cyan) if @@verbose

      local_plugin_paths = plugins_to_upload.map { |name| local_paths[name] }
      rsync_ok = SSHManager.rsync_upload_batch(
        connection_host,
        user,
        local_plugin_paths,
        remote_plugin_dir,
        host.port,
        mode: 0o755
      )

      unless rsync_ok
        puts "   → Rsync unavailable, using scp for #{plugins_to_upload.size} plugins".colorize(:yellow) if @@verbose
        plugins_to_upload.each do |plugin_name|
          SSHManager.upload(
            connection_host,
            user,
            local_paths[plugin_name],
            "#{remote_plugin_dir}/#{plugin_name}",
            host.port,
            mode: 0o755
          )
        end
      end

      # Round trip 3: write all the new .md5 files in one script.
      write_script = String.build do |str|
        plugins_to_upload.each do |plugin_name|
          str << "echo '#{local_md5s[plugin_name]}' > #{remote_plugin_dir}/#{plugin_name}.md5\n"
        end
      end
      SSHManager.exec_script(connection_host, user, write_script, host.port)

      plugins_to_upload.each { |name| @@uploaded_plugins[host_key].add(name) }

      verb = rsync_ok ? "Successfully uploaded" : "Uploaded"
      via = rsync_ok ? "" : " via scp"
      puts "   ✓ #{verb} #{plugins_to_upload.size} plugins#{via}".colorize(:green) if @@verbose
    end

    # fetch: pulls a file FROM the target TO the controller - the reverse
    # direction of every other plugin, which read/write whichever
    # filesystem they end up running on. The normal local/remote dispatch
    # below uploads a plugin binary and executes it directly ON a remote
    # target (forcing ansible_connection=local into its config so its own
    # internal filesystem calls correctly mean "the target's filesystem");
    # that's exactly backwards for fetch, which needs to run on the
    # controller and pull via BasePlugin#remote_download (SSHManager, using
    # the *original*, non-overridden host/vars) instead.
    CONTROLLER_ONLY_PLUGINS = {"fetch", "ansible.builtin.fetch"}

    # Execute a plugin on a host (local or remote)
    def self.execute_plugin(
      plugin_name : String,
      config : JSON::Any,
      host : Host,
      vars : Hash(String, JSON::Any),
    ) : JSON::Any
      return execute_local_plugin(plugin_name, config) if CONTROLLER_ONLY_PLUGINS.includes?(plugin_name)

      # Check if this is a local connection
      is_local = is_local_connection?(host, vars)

      if is_local
        execute_local_plugin(plugin_name, config)
      else
        execute_remote_plugin(plugin_name, config, host, vars)
      end
    end

    # Execute plugin locally
    private def self.execute_local_plugin(plugin_name : String, config : JSON::Any) : JSON::Any
      plugin_path = get_local_plugin_path(plugin_name)

      become, become_user, become_error = resolve_become(config)
      return become_error if become_error

      # Execute plugin with config via stdin using Process
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      begin
        process = if become && (sudo_user = become_user)
                    # No shell involved (args passed as a real argv array,
                    # not interpolated into a command string), so
                    # become_user doesn't need shell-escaping here - unlike
                    # the remote/SSH path below, where it does.
                    Process.new(
                      "sudo",
                      ["-n", "-u", sudo_user, "--", plugin_path],
                      input: Process::Redirect::Pipe,
                      output: stdout,
                      error: stderr
                    )
                  else
                    Process.new(
                      plugin_path,
                      input: Process::Redirect::Pipe,
                      output: stdout,
                      error: stderr
                    )
                  end

        # Write config to stdin
        process.input.print(config.to_json)
        process.input.close

        status = process.wait
        output = stdout.to_s

        # Try to parse JSON output
        begin
          JSON.parse(output)
        rescue ex
          # Parsing failed - return error with details
          JSON.parse({
            "changed"     => false,
            "failed"      => true,
            "msg"         => "Failed to parse plugin output",
            "stdout"      => output,
            "stderr"      => stderr.to_s,
            "parse_error" => ex.message,
          }.to_json)
        end
      rescue ex
        # Execution failed
        JSON.parse({
          "changed" => false,
          "failed"  => true,
          "msg"     => "Plugin execution failed: #{ex.message}",
          "stderr"  => stderr.to_s,
        }.to_json)
      end
    end

    # Execute plugin remotely (uploads if needed, then runs)
    private def self.execute_remote_plugin(
      plugin_name : String,
      config : JSON::Any,
      host : Host,
      vars : Hash(String, JSON::Any),
    ) : JSON::Any
      # Get the actual connection host (checks ansible_host)
      connection_host = get_connection_host(host, vars)

      # Modify config to tell plugin it's running locally on the remote
      config_hash = config.as_h.dup
      if config_hash["vars"]?
        config_hash["vars"].as_h["ansible_connection"] = JSON::Any.new("local")
      else
        config_hash["vars"] = JSON::Any.new({"ansible_connection" => JSON::Any.new("local")})
      end
      modified_config = JSON::Any.new(config_hash)

      become, become_user, become_error = resolve_become(config)
      return become_error if become_error

      target = remote_plugin_target(plugin_name, become, become_user)

      # Execute plugin remotely with modified config via stdin
      command = "echo '#{modified_config.to_json.gsub("'", "'\\''")}' | #{target}"
      result = SSHManager.exec(
        connection_host,
        host.user || "root",
        command,
        host.port
      )

      interpret_remote_result(result[:exit_code], result[:stdout], result[:stderr])
    end

    # Resolves a plugin's remote path (`/tmp/.crystal-play/plugins/<simple
    # name>`) and, if `become`, wraps it in `sudo -n -u <become_user> --`.
    # Shared by the normal one-task-at-a-time remote path above and by
    # TaskExecutor's batch script generation (batching, on by default),
    # so both ways of reaching a remote plugin resolve the exact same
    # target string. `become_user` is expected to
    # already have passed `valid_become_user?` - this only formats, it
    # doesn't validate (the SSH path interpolates the result directly
    # into a shell command, unlike the local/args-array path, so
    # validation happens once, at the call site, before this is ever
    # invoked with untrusted input).
    def self.remote_plugin_target(plugin_name : String, become : Bool, become_user : String?) : String
      simple_name = plugin_name.sub(/^(ansible\.(builtin|legacy|posix)|community\.(general|docker|mysql|postgresql))\./, "")
      remote_plugin_path = "/tmp/.crystal-play/plugins/#{simple_name}"
      become ? "sudo -n -u #{become_user} -- #{remote_plugin_path}" : remote_plugin_path
    end

    # Same become_user allow-list `resolve_become` already enforces,
    # exposed for TaskExecutor's batch path (item 3), which resolves
    # become/become_user per task itself (from Task#become/#become_user,
    # already substituted the same way the non-batched path does) rather
    # than going through the config-JSON-embedded fields resolve_become
    # reads. One shared regex, two call sites, no risk of the two
    # diverging.
    def self.valid_become_user?(user : String) : Bool
      !!user.match(/\A[a-zA-Z_][a-zA-Z0-9_.-]{0,31}\z/)
    end

    # Same interpretation `execute_remote_plugin` already applies to a
    # single task's raw SSH result - exit code wins first (a nonzero exit
    # means the plugin crashed or couldn't run at all, so its stdout, if
    # any, isn't trustworthy JSON), otherwise the plugin's own stdout is
    # parsed as its authoritative result. Exposed so TaskExecutor's batch
    # path (item 3) interprets each step's captured result exactly the
    # same way, instead of re-deriving this logic.
    def self.interpret_remote_result(exit_code : Int32, stdout : String, stderr : String) : JSON::Any
      if exit_code != 0
        return JSON.parse({
          "changed" => false,
          "failed"  => true,
          "msg"     => "Plugin execution failed on remote",
          "stdout"  => stdout,
          "stderr"  => stderr,
        }.to_json)
      end

      begin
        JSON.parse(stdout)
      rescue
        JSON.parse({
          "changed" => false,
          "failed"  => true,
          "msg"     => "Failed to parse plugin output from remote",
          "stdout"  => stdout,
          "stderr"  => stderr,
        }.to_json)
      end
    end

    # Reads become:/become_user: back out of the config JSON (embedded by
    # TaskExecutor#build_plugin_config) and validates become_user, since
    # both execute_local_plugin and execute_remote_plugin need the same
    # become/become_user/error-or-nil triple. Defaults become_user to
    # "root" when become: is set but become_user: wasn't given, matching
    # real Ansible's own default.
    #
    # No become password support (`ansible_become_pass`/
    # `--ask-become-pass`) - sudo always runs with `-n` (non-interactive),
    # so a become_user that needs a password to sudo to fails clearly
    # rather than hanging on a prompt nothing can ever answer. A
    # documented scope cut, not an oversight - matches how `pause:` also
    # has no real interactive-prompt model in this codebase.
    private def self.resolve_become(config : JSON::Any) : {Bool, String?, JSON::Any?}
      become = config["become"]?.try(&.as_s?) == "true"
      return {false, nil, nil} unless become

      become_user = config["become_user"]?.try(&.as_s?)
      become_user = "root" if become_user.nil? || become_user.empty?

      # Interpolated directly into a shell command on the remote/SSH path
      # (SSHManager always runs the whole command through `bash -c`, so
      # there's no args-array primitive to sidestep quoting with there) -
      # a strict allow-list is a real security boundary here, not just a
      # sanity check, so it's enforced for both paths uniformly rather
      # than only where it's strictly required.
      unless valid_become_user?(become_user)
        error = JSON.parse({
          "changed" => false,
          "failed"  => true,
          "msg"     => "become_user #{become_user.inspect} is not a valid username",
        }.to_json)
        return {true, nil, error}
      end

      {true, become_user, nil}
    end

    # Get local plugin path (compiled binary)
    private def self.get_local_plugin_path(plugin_name : String) : String
      # Strip FQCN to get simple plugin filename
      simple_name = plugin_name.sub(/^(ansible\.(builtin|legacy|posix)|community\.(general|docker|mysql|postgresql))\./, "")

      # Resolve plugins/ next to the running binary itself, not relative to
      # the current working directory - otherwise crystal-ansible could
      # only ever be invoked from inside its own checkout (`cd
      # /path/to/crystal-ansible && ./bin/crystal-ansible playbook.yml`),
      # unlike real ansible-playbook, which can run from anywhere.
      if executable = Process.executable_path
        compiled = File.join(File.dirname(executable), "plugins", simple_name)
        return compiled if File.exists?(compiled)
      end

      # Fall back to a cwd-relative lookup (e.g. `crystal run` in dev,
      # where there's no real installed binary to resolve a sibling from).
      compiled = "./bin/plugins/#{simple_name}"
      return compiled if File.exists?(compiled)

      raise "Plugin binary not found: #{plugin_name} (looked for #{compiled})"
    end

    # Check if connection is local. Public - TaskExecutor's batch path
    # (item 3) needs the same local/remote decision execute_plugin
    # already makes internally, before deciding whether batching even
    # applies to a given host.
    def self.is_local_connection?(host : Host, vars : Hash(String, JSON::Any)) : Bool
      # Check if ansible_connection is set to local
      if conn = vars["ansible_connection"]?
        return conn.as_s? == "local"
      end

      # Check if host is localhost
      host.name == "localhost"
    end

    # Get the actual hostname to connect to (checks ansible_host
    # variable). Public - TaskExecutor's batch path needs this to know
    # which host to run the batch script against, same as the
    # non-batched remote path above.
    def self.get_connection_host(host : Host, vars : Hash(String, JSON::Any)) : String
      # Check for ansible_host variable (overrides inventory hostname)
      if ansible_host = vars["ansible_host"]?
        return ansible_host.as_s
      end

      # Fall back to inventory hostname
      host.name
    end

    # Clear uploaded plugins cache (for testing)
    def self.clear_cache
      @@uploaded_plugins.clear
    end
  end
end
