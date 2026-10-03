#!/usr/bin/env crystal

require "json"
require "file_utils"
require "system/user"
require "system/group"
require "openssl/digest"
require "./host"
require "./shell"
require "./ssh_manager"
require "./local_executor"
require "./param_sentinels"
require "./plugin_helpers/strict_bool_params"
require "./plugin_helpers/stat_fields"
require "./plugin_helpers/controlling_tty"
require "./plugin_helpers/ansible_splitlines"

module Krikri
  # LibC::Stat's timestamp fields are named differently per libc: glibc
  # (Linux) uses st_atim/st_mtim/st_ctim, while Darwin's BSD-derived libc
  # uses st_atimespec/st_mtimespec/st_ctimespec for the same `Timespec`
  # struct. Only matters for compiling a macOS controller binary - the
  # plugin binaries this stats normally run on the (Linux) target host,
  # but ansible_connection=local and the controller's own bookkeeping
  # exercise this on whatever host krikri-playbook itself runs on.
  def self.stat_atime_sec(stat : LibC::Stat) : Int64
    {% if flag?(:darwin) %}
      stat.st_atimespec.tv_sec.to_i64
    {% else %}
      stat.st_atim.tv_sec.to_i64
    {% end %}
  end

  def self.stat_mtime_sec(stat : LibC::Stat) : Int64
    {% if flag?(:darwin) %}
      stat.st_mtimespec.tv_sec.to_i64
    {% else %}
      stat.st_mtim.tv_sec.to_i64
    {% end %}
  end

  def self.stat_ctime_sec(stat : LibC::Stat) : Int64
    {% if flag?(:darwin) %}
      stat.st_ctimespec.tv_sec.to_i64
    {% else %}
      stat.st_ctim.tv_sec.to_i64
    {% end %}
  end

  # Float-seconds variants matching Python's own os.stat_result
  # st_atime/st_mtime/st_ctime, which are tv_sec + tv_nsec / 1e9 computed
  # as float64 (CPython combines the two halves the same way) - real
  # Ansible's stat and find results carry that float straight through
  # (e.g. "atime": 1789308974.764945), so truncating to whole seconds
  # broke sub-second timestamp comparisons against real-Ansible output.
  # The *_sec Int64 variants above stay for Time.unix() call sites (file
  # module touch-time change detection) that genuinely want whole
  # seconds.
  def self.stat_atime_f(stat : LibC::Stat) : Float64
    {% if flag?(:darwin) %}
      stat.st_atimespec.tv_sec.to_f + stat.st_atimespec.tv_nsec / 1e9
    {% else %}
      stat.st_atim.tv_sec.to_f + stat.st_atim.tv_nsec / 1e9
    {% end %}
  end

  def self.stat_mtime_f(stat : LibC::Stat) : Float64
    {% if flag?(:darwin) %}
      stat.st_mtimespec.tv_sec.to_f + stat.st_mtimespec.tv_nsec / 1e9
    {% else %}
      stat.st_mtim.tv_sec.to_f + stat.st_mtim.tv_nsec / 1e9
    {% end %}
  end

  def self.stat_ctime_f(stat : LibC::Stat) : Float64
    {% if flag?(:darwin) %}
      stat.st_ctimespec.tv_sec.to_f + stat.st_ctimespec.tv_nsec / 1e9
    {% else %}
      stat.st_ctim.tv_sec.to_f + stat.st_ctim.tv_nsec / 1e9
    {% end %}
  end

  # Plugin result structure with diff support
  class PluginResult
    property? changed : Bool
    property? failed : Bool
    property msg : String
    property diff : JSON::Any?
    property extra : Hash(String, JSON::Any)
    property? omit_changed : Bool
    property? include_empty_msg : Bool
    # A NATIVE-typed msg override (JSON::Any): real modules that pass a
    # non-string value to fail_json/exit_json keep its Python type in the
    # wire result (fail's action puts the raw task arg in result['msg'],
    # so `fail: {msg: 50}` registers and dumps the INT 50, not "50") -
    # the strings-only @msg cannot carry that. When set it replaces @msg
    # in the serialized result entirely; @msg stays "" (the display layer
    # re-renders a non-string msg through Python repr for its error
    # blocks).
    property msg_native : JSON::Any?
    # Optional wire-key order for the serialized result. Real Ansible's
    # registered result is the module's own dict in ITS insertion order
    # (exit_json's msg/status_code kwargs first, then the module's result
    # dict, then add_path_info's stat block) - every module has its own,
    # while PluginResult's fixed leading keys (changed/exception/failed/
    # msg/diff) impose one engine-wide shape. When set, #to_json emits the
    # listed keys first, in the listed order (absent ones skipped), then
    # every remaining key in its current order; nil keeps the historical
    # order on SUCCESS results, while a FAILED result without a key_order
    # takes real's plain fail_json order (failed, msg, then extras, then
    # changed, then exception - see #to_json). Observed programmatically
    # (e.g. `{{ r | to_json }}`,
    # `{{ r }}` in a debug msg) rather than in the -v dump, which real
    # sorts alphabetically via _dump_results(sort_keys=True).
    property key_order : Array(String)?

    def initialize(
      changed : Bool,
      failed : Bool,
      msg : String = "",
      diff : JSON::Any? = nil,
      omit_changed : Bool = false,
      include_empty_msg : Bool = false,
      native_msg : JSON::Any? = nil,
      key_order : Array(String)? = nil,
      **kwargs,
    )
      @changed = changed
      @failed = failed
      @msg = msg
      @diff = diff
      @omit_changed = omit_changed
      @include_empty_msg = include_empty_msg
      @msg_native = native_msg
      @key_order = key_order
      @extra = Hash(String, JSON::Any).new
      kwargs.each do |key, value|
        @extra[key.to_s] = JSON.parse(value.to_json)
      end
    end

    def to_json(io : IO) : Nil
      result = Hash(String, JSON::Any::Type).new
      # omit_changed reproduces real Ansible's CONTROLLER-SIDE failure
      # shape (an uncaught AnsibleError from an action plugin, e.g.
      # fetch's makedirs_safe blowing up on a file-parent dest): the
      # executor's exception handling produces {failed, msg} with no
      # `changed` key at all - unlike a module fail_json result, which
      # _return_formatted always backfills with changed: false. A
      # registered variable from such a failure has `changed`
      # UNDEFINED, and `when: r.changed` on it raises the same
      # "has no attribute" error real Ansible raises.
      result["changed"] = @changed unless @omit_changed
      # fail_json adds exception: "(traceback unavailable)" in 2.19 (seen only
      # through a registered result - the display drops it); controller-side
      # action failures (omit_changed / _ansible_action_level) never carry it
      result["exception"] = "(traceback unavailable)" if @failed && !@omit_changed && !@extra.has_key?("_ansible_action_level")
      # Real Ansible's module protocol (module_utils/basic.py) only adds
      # `failed`/`msg` to the result dict on a fail_json exit - a
      # successful module's wire result never carries either key at all
      # (not a display-layer strip; callbacks pass the dict through).
      # Exception: a module that passes msg='' to exit_json EXPLICITLY
      # (e.g. git_config's already-converged no-op) still gets the empty
      # key - include_empty_msg opts into that.
      result["failed"] = @failed if @failed
      add_msg(result)

      # Add diff if present
      if diff = @diff
        result["diff"] = diff.raw # Extract the raw value from JSON::Any
      end

      # Add extra fields
      @extra.each do |key, value|
        next if key == "failed_flag"
        result[key] = value.raw # Extract the raw value from JSON::Any
      end
      # command.py-style modules report `failed: false` explicitly on success
      result["failed"] = false if @extra.has_key?("failed_flag") && !@failed

      if order = @key_order
        emit_reordered(result, order, io)
      elsif @failed
        # Default FAILED order - real's fail_json shape, live-verified
        # across seven plugins' plain failures (slurp missing file, stat
        # unsupported parameter, file bad state, fail:, service missing
        # service, getent unknown database, mount unmkdirable path - all
        # register exactly failed, msg, changed, exception). Modules that
        # pass extra kwargs to fail_json keep them positioned by the
        # kwargs-first rule (rc/elapsed/cmd lead), which needs per-plugin
        # key_order; the default here only covers the plain shape.
        failed_order = ["failed", "msg", "diff"]
        result.each_key do |key|
          next if key.in?("failed", "msg", "diff", "changed", "exception")
          failed_order << key
        end
        failed_order << "changed"
        failed_order << "exception"
        emit_reordered(result, failed_order, io)
      else
        result.to_json(io)
      end
    end

    # Serializes *result* with the keys named in *order* first (absent ones
    # skipped), then every unlisted key in its existing insertion order -
    # real Ansible's module-dict wire shape (see @key_order's comment).
    private def emit_reordered(result : Hash(String, JSON::Any::Type), order : Array(String), io : IO) : Nil
      ordered = Hash(String, JSON::Any::Type).new
      order.each do |key|
        ordered[key] = result[key] if result.has_key?(key)
      end
      result.each do |key, value|
        ordered[key] = value unless ordered.has_key?(key)
      end
      ordered.to_json(io)
    end

    # A non-string `msg` (a YAML list/dict/bool) has to reach the wire
    # with its own type, not stringified; an absent one is omitted
    # unless the module explicitly passed an empty msg.
    private def add_msg(result : Hash(String, JSON::Any::Type)) : Nil
      if native = @msg_native
        result["msg"] = native.raw
      elsif !@msg.empty? || @include_empty_msg
        result["msg"] = @msg
      end
    end
  end

  # Raised by the shared owner/group resolvers when a PRESENT owner:/
  # group: value doesn't resolve to a real system user/group. Real
  # Ansible's basic.py set_owner_if_different/set_group_if_different
  # only skip the chown/chgrp when the param is None - an explicit empty
  # string is still looked up and fails the task with exactly
  # "chown failed: failed to look up user <name>" (basic.py:789) or
  # "chgrp failed: failed to look up group <name>" (basic.py:830),
  # trailing space included when <name> is empty. Found benchmarking
  # kilip.chezmoi (round900811): owner: "" was silently treated as "no
  # ownership change requested" instead of failing like this.
  class OwnerLookupFailure < Exception; end

  # Base class for all plugins
  abstract class BasePlugin
    property host : Host
    property params : Hash(String, String)
    property vars : Hash(String, JSON::Any)
    property config : JSON::Any
    property? diff_mode : Bool

    # Params the module call carried as an explicit null/None - see
    # NONE_SENTINEL for why this needs bookkeeping at all.
    @null_params = Set(String).new

    # Params the parser marked as non-string YAML scalar literals (see
    # NON_STRING_PARAM_PREFIX): key -> the decoded native value
    # (Int64/Float64/Bool). @params itself holds the demoted plain string,
    # so plugins that never ask see exactly the text they always did.
    @non_string_params = Hash(String, JSON::Any).new

    # Params the parser comma-joined from a YAML list whose members were
    # marked non-string scalars (NON_STRING_MEMBER_PREFIX): key -> the
    # decoded members in wire order. @params holds the demoted comma
    # join, which is indistinguishable from a plain string, so a plugin
    # mirroring real's str()/repr() of a list-valued arg needs this.
    @non_string_member_lists = Hash(String, Array(JSON::Any)).new

    def explicit_null_param?(key : String) : Bool
      @null_params.includes?(key)
    end

    # The native YAML value (JSON::Any) a param carried as a non-string
    # scalar literal, or nil when it is a string/templated value - the
    # plugin-side view of the parser's NON_STRING_PARAM_PREFIX marker, for
    # mirroring real action plugins' Python type checking (copy/fetch/
    # template dest/src).
    def non_string_param(key : String) : JSON::Any?
      @non_string_params[key]?
    end

    # The decoded members of a param the parser comma-joined from a YAML
    # list with at least one marked non-string member (see the
    # @non_string_member_lists comment), or nil.
    def non_string_member_list(key : String) : Array(JSON::Any)?
      @non_string_member_lists[key]?
    end

    # Python truthiness of one param, native-type aware: a marked
    # non-string literal carries its own truthiness (false/0/0.0 are
    # falsy exactly like in Python), anything else is truthy unless it is
    # absent or the empty string. Distinct from Krikri.python_param_truthy?
    # because the demoted @params value has already lost the marker - the
    # native value is consulted from @non_string_params instead.
    protected def python_param_truthy?(key : String) : Bool
      if native = @non_string_params[key]?
        case native.raw
        when Bool    then native.as_bool
        when Int64   then native.as_i64 != 0
        when Float64 then native.as_f != 0.0
        else              true
        end
      else
        value = @params[key]?
        !value.nil? && !value.empty?
      end
    end

    # module_utils get_bin_path(required=True) failure text: the module
    # process's PATH plus /sbin, /usr/sbin, /usr/local/sbin when missing from
    # it and present on disk, with the executable name double-quoted.
    protected def missing_executable_message(name : String) : String
      paths = (ENV["PATH"]? || "").split(':')
      {"/sbin", "/usr/sbin", "/usr/local/sbin"}.each do |dir|
        paths << dir if !paths.includes?(dir) && Dir.exists?(dir)
      end
      %(Failed to find required executable "#{name}" in paths: #{paths.join(':')})
    end

    # Directories searched beyond $PATH by real Ansible's get_bin_path
    # (module_utils/common/process.py): PATH first, then /sbin,
    # /usr/sbin, /usr/local/sbin.
    private BIN_EXTRA_DIRS = %w[/sbin /usr/sbin /usr/local/sbin]

    @bin_searched_paths = ""

    # Shell-probed get_bin_path(required=True) equivalent, working for
    # both local and SSH connections (the plugin process's own PATH can
    # differ from the remote shell's). Records the directories actually
    # searched in @bin_searched_paths for the failure message, and
    # returns the resolved absolute path (or nil when nothing
    # executable is found anywhere).
    protected def find_required_binary(name : String) : String?
      dirs = %($(printf '%s' "$PATH" | tr ':' ' ') #{BIN_EXTRA_DIRS.join(' ')})
      script = <<-SH
        searched=""
        found=""
        for d in #{dirs}; do
          case ":$searched:" in *":$d:"*) continue ;; esac
          searched="${searched:+$searched:}$d"
          if [ -z "$found" ] && [ -x "$d/#{name}" ]; then found="$d/#{name}"; fi
        done
        printf 'searched=%s\n' "$searched"
        printf 'found=%s\n' "$found"
        SH

      searched = ""
      found = ""
      remote_exec(script)[:stdout].to_s.each_line do |line|
        key, _, value = line.strip.partition("=")
        searched = value if key == "searched"
        found = value if key == "found"
      end
      @bin_searched_paths = searched
      found.empty? ? nil : found
    end

    # Python str(timedelta) for a sub-day span: H:MM:SS.ffffff
    protected def python_delta(span : Time::Span) : String
      total_us = span.total_microseconds.to_i64
      seconds, micros = total_us.divmod(1_000_000_i64)
      minutes, secs = seconds.divmod(60_i64)
      hours, mins = minutes.divmod(60_i64)
      "#{hours}:#{mins.to_s.rjust(2, '0')}:#{secs.to_s.rjust(2, '0')}.#{micros.to_s.rjust(6, '0')}"
    end

    # command/shell's failed os.chdir(): real's fatal msg is the generic
    # "Unable to change directory before execution." while the [ERROR] block
    # shows the OSError text too (Python bytes repr of the path).
    protected def chdir_error_detail(path : String) : String
      errno = File.exists?(path) ? "[Errno 20] Not a directory" : "[Errno 2] No such file or directory"
      "Unable to change directory before execution: #{errno}: b'#{path}'"
    end

    def initialize(@config : JSON::Any)
      @host = Host.from_json(@config["host"])

      # Parse params
      @params = Hash(String, String).new
      if params_json = @config["params"]?
        params_json.as_h.each do |key, value|
          # An explicit JSON null on the wire (or the executor's
          # NONE_SENTINEL for a template that natively resolved to
          # Python None) records as a null param and demotes to "" -
          # NOT value.to_s, which would erase the null-vs-empty-string
          # distinction real Ansible's argspec coercion cares about.
          if value.raw.nil? || value.as_s? == NONE_SENTINEL
            @null_params << key
            @params[key] = ""
          elsif (native = Krikri.non_string_scalar(value.as_s?))
            # A parser-marked non-string YAML literal: demote to the same
            # plain string stringify_value always produced (no plugin that
            # never asks changes behavior) and remember the native value
            # for #non_string_param.
            @non_string_params[key] = native
            @params[key] = Krikri.non_string_param_text(native)
          elsif (text = value.as_s?) && (text.includes?(Krikri::NON_STRING_PARAM_PREFIX) || text.includes?(Krikri::NON_STRING_MEMBER_PREFIX))
            # Marked non-string MEMBERS inside a parser comma-joined list
            # (see parse_module_params's list branch): demote them the
            # same way, so every plugin's own split(',') keeps seeing the
            # plain member text it always did.
            if members = Krikri.non_string_list_members(text)
              @non_string_member_lists[key] = members
            end
            @params[key] = Krikri.strip_non_string_markers_in_value(text)
          else
            @params[key] = value.to_s
          end
        end
      end

      # Parse vars
      @vars = Hash(String, JSON::Any).new
      if vars_json = @config["vars"]?
        vars_json.as_h.each do |key, value|
          @vars[key] = value
        end
      end

      # Check for diff mode
      @diff_mode = true?(@params["_ansible_diff"]?)
    end

    # Abstract method - must be implemented by subclasses
    abstract def execute : PluginResult

    # Run the plugin and output JSON result
    def run : Nil
      puts run_and_capture
    end

    # Same as #run, but returns the JSON result as a String instead of
    # printing it - the piece #run itself needs, and also what the
    # persistent daemon dispatch (SUGGESTED_PERFORMANCE_IMPROVEMENTS.md
    # item #15 - see plugin_daemon.cr) needs: a daemon serves many
    # requests over one long-lived process, so it can never rely on
    # #run's "print to the real STDOUT" behavior - each response has to
    # be framed and written by the daemon loop itself, not by the
    # plugin. Behavior-preserving split: #run is now a one-line wrapper
    # around this, so every existing one-shot call site (every plugin's
    # own driver trailer) is unaffected.
    def run_and_capture : String
      execute.to_json
    rescue ex : BoolParamError
      # The message is already the exact user-facing failure real Ansible
      # produces at module setup (parameters.py's check_type_bool wrapper,
      # live-verified against ansible-core 2.19.11) - surface it verbatim
      # instead of the generic "Plugin execution failed: " wrapper real
      # never produces, same reasoning as the OwnerLookupFailure rescue
      # below.
      PluginResult.new(changed: false, failed: true, msg: ex.message || "invalid boolean parameter").to_json
    rescue ex : OwnerLookupFailure
      # The message is already the exact user-facing failure real
      # Ansible produces ("chown failed: failed to look up user <name>"
      # / "chgrp failed: failed to look up group <name>") - surface it
      # verbatim instead of under the generic "Plugin execution failed: "
      # wrapper real never produces (same reasoning as file.cr's own
      # dispatch_state_rescued). The shared resolvers deliberately raise
      # rather than return PluginResult so every plugin applying
      # file-common owner:/group: args gets real Ansible's failure shape
      # without each one hand-rolling it.
      PluginResult.new(changed: false, failed: true, msg: ex.message || "owner lookup failed").to_json
    rescue ex : Exception
      error_result = PluginResult.new(
        changed: false,
        failed: true,
        msg: "Plugin execution failed: #{ex.message}"
      )
      STDERR.puts ex.backtrace.join("\n")
      error_result.to_json
    end

    # Helper methods for remote execution
    # Supports both SSH and local connections

    # Check if this host should use local connection
    protected def local_connection? : Bool
      # The CONFIG's host is authoritative for where this plugin process
      # is actually running, so the localhost name check must win over
      # @vars: on a delegate_to: localhost task, the config's vars belong
      # to the ORIGIN host (build_vars_context injects
      # ansible_connection="ssh" for every non-local origin host), and
      # the old vars-first order saw that "ssh" and made the plugin's own
      # file/remote helpers SSH back to localhost:22 - connection refused
      # on any controller without sshd. Found via cloudalchemy.
      # mysqld_exporter (round 195): its `delegate_to: localhost`
      # unarchive task failed with "Source ... failed to transfer" after
      # the executor-side fix correctly routed the task to a local plugin
      # spawn but the plugin's internals still misread the connection.
      # (An explicit inventory localhost with ansible_connection=ssh is
      # not distinguishable here - config["host"] carries only name/user/
      # port - and stays unsupported; real Ansible's IMPLICIT localhost
      # is always local, which is the case this models.)
      return true if @host.name == "localhost" || @host.name == "127.0.0.1"

      # Check if ansible_connection is set to local
      if conn = @vars["ansible_connection"]?
        return conn.as_s? == "local"
      end

      false
    end

    # Get the actual hostname to connect to (checks ansible_host variable)
    protected def get_connection_host : String
      # Check for ansible_host variable (overrides inventory hostname)
      if ansible_host = @vars["ansible_host"]?
        return ansible_host.as_s
      end

      # Fall back to inventory hostname
      @host.name
    end

    # ansible_ssh_private_key_file, if the inventory specifies one -
    # nil (ssh's own default identity/agent resolution) otherwise.
    protected def get_identity_file : String?
      @vars["ansible_ssh_private_key_file"]?.try(&.as_s?)
    end

    # timeout: overrides SSHManager's own default per-call process
    # timeout (SSHManager::DEFAULT_EXEC_TIMEOUT_SECONDS, 3600s) - unused
    # by every existing caller (all happy with that default), added for
    # wait_for_connection: (see plugins/wait_for_connection.cr), whose
    # whole job is retrying a short, bounded connection probe rather
    # than waiting the normal hour-long ceiling on each attempt.
    protected def remote_exec(command : String, timeout : Int32? = nil, force_shell : Bool = false) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
      command = with_environment(command)
      if local_connection?
        # Execute locally
        LocalExecutor.exec(command, force_shell: force_shell)
      else
        # Execute via SSH - use ansible_host if set
        SSHManager.exec(
          get_connection_host,
          @host.user || "root",
          command,
          @host.port,
          timeout: timeout || SSHManager::DEFAULT_EXEC_TIMEOUT_SECONDS,
          identity_file: get_identity_file
        )
      end
    end

    # Prefixes *command* with `export K='V'; ...` for each entry in the
    # task's `environment:` (real Ansible's per-task env-var keyword,
    # forwarded here as a JSON blob under the `_environment` param key by
    # TaskExecutor#build_plugin_config, already {{ }}-substituted). One
    # shared implementation so every plugin that shells out via
    # #remote_exec gets `environment:` support automatically rather than
    # each plugin needing its own wiring.
    private def with_environment(command : String) : String
      env_json = @params["_environment"]?
      return command unless env_json

      env = Hash(String, String).from_json(env_json)
      return command if env.empty?

      # The KEY must be a valid POSIX identifier before it can be
      # interpolated into the export list: the export string is executed by
      # a real shell (LocalExecutor falls through to /bin/bash -c, and the
      # remote side runs `ssh host <string>`), so a task-controlled key like
      # `X; touch /tmp/pwned; #` would execute there. The VALUE side is
      # safe (Shell.single_quote below); real Ansible hands the dict to
      # subprocess's env and cannot execute through a key, so any key it
      # would have honored as a real env name passes this check too.
      exports = env.map do |key, value|
        unless key.matches?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
          raise ArgumentError.new(
            "Invalid environment variable name #{key.inspect} in task " \
            "environment: keys must match [A-Za-z_][A-Za-z0-9_]*"
          )
        end
        "export #{key}=#{shell_single_quote(value)}"
      end.join("; ")
      "#{exports}; #{command}"
    end

    # Single-quotes *str* for shell embedding - shared implementation in
    # ./shell.cr (was its own copy, drift risk for a security-relevant
    # primitive).
    private def shell_single_quote(str : String) : String
      Shell.single_quote(str)
    end

    # SECURITY: a staging temp file that will hold copy/template/
    # lineinfile-style content must never hold those bytes at a wider
    # mode than the content's final one. Creating the temp with a
    # default perm (0644 & ~umask) and chmod-ing only after the write
    # leaves the bytes briefly readable at the wider mode - the
    # create-then-chmod window the vault-decrypted staging
    # (TaskExecutor#stage_vault_decrypted_source) and
    # AsyncJobs.write_status already avoid by settling the mode BEFORE
    # the payload lands. This creates *path* EMPTY at 0600 (narrow under
    # any umask), then settles it to *mode* while still empty - widening
    # an empty file is harmless; widening one that already holds the
    # secret is exactly the bug. Callers pass the mode already narrowed
    # by #staging_temp_mode, so this never creates wide-then-narrow.
    private def create_staging_temp(path : String, mode : Int32) : Nil
      File.write(path, "", perm: 0o600)
      File.chmod(path, mode)
    end

    # The mode a staging temp should be settled at before content lands
    # in it: the task's own numeric `mode:` (the authoritative final
    # mode - re-applying it post-write is a no-op, so final-state
    # behavior is unchanged), or when no numeric mode is given, the
    # existing dest's own mode when one is being overwritten (the
    # rename carries the temp's mode across, and real Ansible's
    # atomic_move preserves an existing dest's mode), or *new_file_base*
    # & ~umask for a not-yet-existing dest (copy's atomic_move gives a
    # new dest 0666 & ~umask; the File.write-defaulted staging paths
    # give 0644 & ~umask). A symbolic `mode:` can't be resolved to
    # absolute bits here and is left to the post-write chmod - which is
    # narrow-then-widen, never the reverse. *preserve_dest_mode* is
    # false for staging paths where the temp never inherits the dest's
    # mode today (the /tmp validate: staging that is mv'd in as a new
    # inode, and temps that are deleted after use). *apply_task_mode*
    # is false for the module whose real counterpart does NOT pre-apply
    # the task's numeric mode: at creation time - real's
    # set_fs_attributes_if_different must see the 0666 & ~umask (or
    # preserved) creation mode and report the drift itself
    # (lineinfile's "line added and ownership, perms or SE linux
    # context changed" msg suffix depends on that post-write drift
    # being real; live-verified vs 2.19.11).
    private def staging_temp_mode(dest : String, new_file_base : Int32, preserve_dest_mode : Bool = true, apply_task_mode : Bool = true) : Int32
      if apply_task_mode && (raw_mode = @params["mode"]?.presence) && raw_mode =~ /\A0?[0-7]{3,4}\z/
        return raw_mode.to_i(8)
      end

      dest_mode = begin
        if preserve_dest_mode && !File.symlink?(dest) && (info = File.info?(dest, follow_symlinks: false))
          info.permissions.value.to_i32
        end
      rescue File::Error
        # Stat itself failed (broken dest?) - fall through to the
        # not-yet-existing default, matching the old stat-preservation
        # blocks' "proceed without preservation" on stat errors.
        nil
      end

      dest_mode || (new_file_base & ~creation_umask)
    end

    # Reads the process umask. POSIX has no read-only umask call, so
    # this does the classic set-read-restore dance around a maximally
    # restrictive value - the same dance real Ansible's atomic_move does
    # and this repo's own spec helpers use; the window where a
    # concurrent creator would inherit the temporary mask is two
    # adjacent syscalls, and plugin module code is single-threaded.
    private def creation_umask : Int32
      umask = LibC.umask(0o077)
      LibC.umask(umask)
      umask.to_i32
    end

    # Atomic move with the cross-device fallback real Ansible's
    # AnsibleModule.atomic_move provides: try rename(2) first, and on
    # EXDEV specifically (temp under /tmp or ~, dest on a different
    # mount - found on konstruktoid.hardening's openssh_keypair task,
    # where /tmp is a separate tmpfs from /etc), fall back to a
    # copy-then-delete that carries the source's mode/owner/group onto
    # the destination. Other OSError kinds still propagate. Non-atomic
    # on the fallback path, exactly as in real Ansible.
    protected def atomic_move(src : String, dest : String) : Nil
      begin
        File.rename(src, dest)
        return
      rescue ex : File::Error
        raise ex unless ex.os_error.try(&.value) == Errno::EXDEV.value
      end

      src_info = File.info(src, follow_symlinks: false)
      File.open(src, "r") do |in_file|
        File.open(dest, "wb", perm: src_info.permissions) do |out_file|
          IO.copy(in_file, out_file)
        end
      end
      File.chmod(dest, src_info.permissions)
      begin
        File.chown(dest, uid: src_info.owner_id.to_i, gid: src_info.group_id.to_i)
      rescue File::Error
        # Best-effort, matching the copy plugin's own chown stance:
        # non-root can't chown; the copy still lands correct-mode.
      end
      File.delete(src)
    end

    protected def remote_upload(local_path : String, remote_path : String) : Nil
      if local_connection?
        # Just copy locally
        FileUtils.cp(local_path, remote_path)
      else
        SSHManager.upload(
          get_connection_host,
          @host.user || "root",
          local_path,
          remote_path,
          @host.port,
          identity_file: get_identity_file
        )
      end
    end

    protected def remote_download(remote_path : String, local_path : String) : Nil
      if local_connection?
        # Just copy locally
        FileUtils.cp(remote_path, local_path)
      else
        SSHManager.download(
          get_connection_host,
          @host.user || "root",
          remote_path,
          local_path,
          @host.port,
          identity_file: get_identity_file
        )
      end
    end

    protected def remote_file_exists?(path : String) : Bool
      if local_connection?
        LocalExecutor.file_exists?(path)
      else
        result = remote_exec("test -f #{shell_single_quote(path)}")
        result[:exit_code] == 0
      end
    end

    protected def remote_dir_exists?(path : String) : Bool
      if local_connection?
        LocalExecutor.dir_exists?(path)
      else
        result = remote_exec("test -d #{shell_single_quote(path)}")
        result[:exit_code] == 0
      end
    end

    # A native stat()/lstat() syscall (no `stat`/`md5sum`/etc. subprocess
    # spawn) - always operates directly on this process's own filesystem,
    # not through remote_exec's local/SSH split: PluginManager already
    # uploads and executes this same compiled plugin binary directly on
    # the remote host for non-local connections (see
    # execute_remote_plugin), so "the filesystem this process can see" IS
    # the target host's filesystem either way. Returns nil if the path
    # doesn't exist (or isn't statable for some other reason - permission
    # denied, a dangling symlink with follow: true, etc.).
    protected def native_stat(path : String, follow : Bool) : Hash(String, JSON::Any)?
      stat_or_errno = native_stat_ex(path, follow)
      stat_or_errno.is_a?(Hash(String, JSON::Any)) ? stat_or_errno : nil
    end

    # The errno-bearing variant: real Ansible's stat module only treats
    # ENOENT as "exists: false" and hard-fails on every other OSError
    # with strerror as the message (stat.py, all active branches) - a
    # stat whose parent is a file (ENOTDIR) or an unreadable ancestor
    # (EACCES) is a failed task, not a silent exists: false. Callers
    # that reproduce the real module's error surface use this and map
    # non-ENOENT errnos to failure themselves.
    protected def native_stat_ex(path : String, follow : Bool) : Hash(String, JSON::Any)? | Errno
      stat = uninitialized LibC::Stat
      result = follow ? LibC.stat(path, pointerof(stat)) : LibC.lstat(path, pointerof(stat))
      return Errno.value if result != 0

      # An orphaned uid/gid with no matching /etc/passwd or /etc/group
      # entry resolves to an EMPTY string in real Ansible's own stat
      # (and find's per-file) result, not the stringified numeric id -
      # robertdebock.unowned_files' own `item.pw_name | length == 0`
      # check (and community.general's wider "unowned files" idiom)
      # depends on this exact empty-string convention to detect an
      # orphaned owner/group at all. Falling back to the numeric id
      # (non-empty) meant that check silently never matched anything.
      pw_name = System::User.find_by?(id: stat.st_uid.to_s).try(&.username) || ""
      gr_name = System::Group.find_by?(id: stat.st_gid.to_s).try(&.name) || ""

      PluginHelpers::StatFields.build(
        path,
        mode: stat.st_mode.to_i32,
        size: stat.st_size.to_i64,
        uid: stat.st_uid.to_i64,
        gid: stat.st_gid.to_i64,
        pw_name: pw_name,
        gr_name: gr_name,
        atime: Krikri.stat_atime_f(stat),
        mtime: Krikri.stat_mtime_f(stat),
        ctime: Krikri.stat_ctime_f(stat),
        inode: stat.st_ino.to_i64,
        dev: stat.st_dev.to_i64,
        nlink: stat.st_nlink.to_i64,
        block_size: stat.st_blksize.to_i64,
        blocks: stat.st_blocks.to_i64,
        device_type: stat.st_rdev.to_i64,
      )
    end

    # Native MD5/SHA1/SHA224/SHA256/SHA384/SHA512 file checksum (no
    # `md5sum`/`sha1sum`/`sha256sum` subprocess spawn) - streams the
    # file through OpenSSL's generic EVP digest API rather than loading
    # it fully into memory.
    #
    # Every algorithm other than md5/sha256 used to silently fall
    # through to the `else` branch (SHA1) regardless of what was asked
    # for - get_url:'s own `checksum: "sha384:..."` (geerlingguy.
    # composer's own "Download Composer installer." task, verifying
    # against the officially published installer signature) computed a
    # 40-hex-char SHA1 digest against a 96-hex-char SHA384 expected
    # value, always reporting "checksum mismatch" regardless of whether
    # the download was genuinely correct.
    protected def native_checksum(path : String, algorithm : String) : String
      openssl_name = case algorithm.downcase
                     when "md5"    then "MD5"
                     when "sha1"   then "SHA1"
                     when "sha224" then "SHA224"
                     when "sha256" then "SHA256"
                     when "sha384" then "SHA384"
                     when "sha512" then "SHA512"
                     else               "SHA1"
                     end

      digest = OpenSSL::Digest.new(openssl_name)
      digest.file(path)
      digest.final.hexstring
    end

    # Real Ansible's AnsibleModule.add_path_info (module_utils/basic.py),
    # which its _return_formatted runs over EVERY module result (both
    # exit_json and fail_json): any result whose `path` (or `dest`) key
    # points at a path that STILL EXISTS at module-exit time gets the
    # file-common stat fields merged in - uid/gid/owner/group (login
    # names, falling back to the stringified numeric id exactly like
    # basic.py's pwd.getpwuid/grp.getgrgid KeyError rescue, NOT the
    # empty-string orphan convention native_stat's stat-module output
    # uses), mode (zero-padded octal of the LSTAT'd permission bits, so
    # a symlink reports its own "0777"), state ("link"/"directory"/
    # "hard" for a regular file with nlink > 1/"file"), and size.
    #
    # Existence is checked through the link (os.path.exists), so a
    # DANGLING symlink - unstatable through the link - gets no fields
    # at all, matching basic.py exactly.
    #
    # This is the shared protocol layer real Ansible's add_file_common_args
    # machinery provides to every file-touching module (file/copy/
    # get_url/...), so a state=absent --check on an existing file reports
    # the file's PRE-removal stats with state "file" (the file still
    # exists when the module exits), while the same task for real
    # reports only state "absent" (the path is gone by exit time, so
    # this no-ops). A result for a path that doesn't exist is left
    # untouched - no fields added - also matching real Ansible.
    protected def add_path_info(result : PluginResult, path : String) : Nil
      return if path.empty?
      return unless File.exists?(path)
      stat_hash = native_stat(path, follow: false)
      return unless stat_hash

      result.extra["uid"] = stat_hash["uid"]
      result.extra["gid"] = stat_hash["gid"]
      owner = stat_hash["pw_name"].as_s
      result.extra["owner"] = JSON::Any.new(owner.empty? ? stat_hash["uid"].as_i64.to_s : owner)
      group = stat_hash["gr_name"].as_s
      result.extra["group"] = JSON::Any.new(group.empty? ? stat_hash["gid"].as_i64.to_s : group)
      result.extra["mode"] = stat_hash["mode"]
      result.extra["state"] = JSON::Any.new(
        if stat_hash["islnk"].as_bool
          "link"
        elsif stat_hash["isdir"].as_bool
          "directory"
        elsif stat_hash["isreg"].as_bool && stat_hash["nlink"].as_i64 > 1
          "hard"
        else
          "file"
        end
      )
      result.extra["size"] = stat_hash["size"]
    end

    # Expands a leading `~` or `~username` the same way Python's own
    # os.path.expanduser does - real Ansible's path-type params go
    # through this before any existence check. geerlingguy.composer's
    # own `composer_home_path: '~/.composer'` default feeds straight
    # into command:'s `creates={{ composer_home_path }}/vendor/{{
    # item.name }}`; checking that literal "~/.composer/vendor/..."
    # string against the filesystem can never match (`~` is not a real
    # path component), so the task reported changed: true on every
    # single run, never converging - a real idempotency bug, not the
    # role's fault (real Ansible's own AnsibleModule expands `~` for
    # every path-type arg, creates/removes/chdir included).
    protected def expand_tilde(path : String) : String
      return path unless path.starts_with?('~')

      rest = path[1..]
      username, _, remainder = rest.partition('/')
      home = if username.empty?
               # Python's own os.path.expanduser checks $HOME FIRST for the
               # bare `~` case, only falling back to the passwd entry if HOME
               # is unset - matches plugin_helpers/mysql_connection.cr's own
               # copy of this same expansion, which already had it right.
               ENV["HOME"]? || System::User.find_by?(id: LibC.getuid.to_s).try(&.home_directory)
             else
               System::User.find_by?(name: username).try(&.home_directory)
             end
      return path unless home

      remainder.empty? ? home : File.join(home, remainder)
    end

    # command:/shell:'s own `creates:`/`removes:` idempotency check -
    # real Ansible's own module (Python's `glob.glob(path)`, then "any
    # match") treats the path as a GLOB PATTERN, not a literal path -
    # `File.exists?` alone never matches a path containing `*`/`?`/`[`
    # (those are never literal filenames), always reporting "does not
    # exist" and re-running the command on every single invocation.
    # Found via appsilon.mount_efs's own "install | build amazon-efs-
    # utils" (`creates: "{{ aws_efs_utils_dest_dir }}/build/amazon-efs-
    # utils*deb"`) - a real idempotency bug: the build script re-ran on
    # every warm rerun instead of correctly no-opping once the package
    # was already built. `Dir.glob` degrades to a literal single-path
    # existence check automatically when *path* has no glob
    # metacharacters at all, so this is safe for the far more common
    # literal-path case too - not just the glob one.
    protected def path_or_glob_exists?(path : String) : Bool
      !Dir.glob(path).empty?
    end

    # Helper to check if a parameter is truthy - real Ansible's own
    # BOOLEANS_TRUE (module_utils/parsing/convert_bool.py): y/yes/on/1/
    # true/t.
    protected def true?(value : String?, default : Bool = false) : Bool
      return default unless value
      ["true", "yes", "1", "on", "y", "t"].includes?(value.downcase)
    end

    # Helper to check if a parameter is explicitly falsy - the mirror of
    # #true? for plugins that need to distinguish "not given" from "given
    # as false" (a nil param is neither). Real Ansible's own
    # BOOLEANS_FALSE: n/no/off/0/false/f. Kept next to #true? so the two
    # lists can never drift apart (they used to live only in yum/dnf's
    # private copies).
    protected def false?(value : String?) : Bool
      return false unless value
      ["false", "no", "0", "off", "n", "f"].includes?(value.downcase)
    end

    # --- strict `type: bool` param validation (real check_type_bool) ---
    #
    # Shared with the controller-side action plugins through
    # PluginHelpers::StrictBoolValidation (see that module's block comment
    # for the real-Ansible semantics, wording provenance and opt-in
    # contract). A plugin opts in by overriding #bool_params (plus
    # #bool_param_aliases / #bool_params_none_default where real's argspec
    # has them) and calling #validate_bool_params! where real's
    # module-setup validation would sit in its own arg-check ordering.
    include PluginHelpers::StrictBoolValidation

    # Convenience wrapper: pulls the raw param wire off the plugin config
    # and runs the shared validator over it.
    protected def validate_bool_params! : Nil
      raw_params = @config["params"]?.try(&.as_h?) || return nil
      validate_bool_params_in!(raw_params)
    end

    # Owner/group name -> uid/gid for the file-common owner:/group: args,
    # shared by every plugin that applies them. Real Ansible's basic.py
    # treats only a None owner/group as "no change requested" - a present
    # value, INCLUDING an explicit empty string, is always looked up and
    # an unresolvable name fails the task (see OwnerLookupFailure). All-
    # digit strings are raw uid/gids, matching real Ansible's int(owner)
    # fast path (and file.cr's own resolve_uid/resolve_gid).
    protected def resolve_owner_uid(owner : String) : Int32
      if user = System::User.find_by?(name: owner)
        user.id.to_i
      elsif owner.matches?(/\A\d+\z/)
        owner.to_i
      else
        raise OwnerLookupFailure.new("chown failed: failed to look up user #{owner}")
      end
    end

    protected def resolve_group_gid(group : String) : Int32
      if grp = System::Group.find_by?(name: group)
        grp.id.to_i
      elsif group.matches?(/\A\d+\z/)
        group.to_i
      else
        raise OwnerLookupFailure.new("chgrp failed: failed to look up group #{group}")
      end
    end

    # Applies owner/group/numeric mode to a single path natively
    # (`File.chown`/`File.chmod`) instead of shelling to
    # `chown`/`chgrp`/`chmod` - shared by plugins (`apt_repository`,
    # `yum_repository`) that write a single config file and then apply
    # ownership/permissions to it. A *symbolic* mode string (`u+x`) can't
    # be resolved without reimplementing chmod(1)'s symbolic grammar, so
    # it still shells to `chmod` for that one case - see `file.cr`'s own
    # class doc comment for the same trade-off, made first there.
    # EPERM and friends are swallowed (as in every prior shell-based
    # version of this logic, which never checked chown/chgrp/chmod's exit
    # code), but an unresolvable owner/group NAME fails the task like
    # real Ansible's basic.py - an empty string included (see
    # OwnerLookupFailure).
    protected def apply_owner_group_mode(path : String, owner : String?, group : String?, mode : String?) : Nil
      uid = owner ? resolve_owner_uid(owner) : -1
      gid = group ? resolve_group_gid(group) : -1

      File.chown(path, uid: uid, gid: gid) if uid != -1 || gid != -1

      if mode
        if numeric = mode.to_i?(8)
          File.chmod(path, numeric)
        else
          remote_exec("chmod #{shell_single_quote(mode)} #{shell_single_quote(path)}")
        end
      end
    rescue File::Error
      # EPERM and friends - the documented swallow (unresolvable
      # owner/group names fail above via OwnerLookupFailure instead;
      # only the syscalls raise here).
    end

    # Generate unified diff
    protected def generate_unified_diff(before : String, after : String, before_header : String = "before", after_header : String = "after") : JSON::Any
      JSON.parse({
        "before"        => before,
        "after"         => after,
        "before_header" => before_header,
        "after_header"  => after_header,
      }.to_json)
    end

    # Generate attribute diff
    protected def generate_attribute_diff(before : Hash(String, String), after : Hash(String, String)) : JSON::Any
      JSON.parse({
        "before" => before,
        "after"  => after,
      }.to_json)
    end
  end
end
