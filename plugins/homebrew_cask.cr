#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # ansible.builtin.homebrew_cask - macOS Homebrew cask management.
  #
  # ansible-core's own builtin runtime redirects the ansible.builtin
  # spelling to community.general.homebrew_cask and RUNS it, exactly like
  # ansible.builtin.homebrew (issue #777), so the graceful
  # unavailable-module skip diverged on rooland-provisioning.atom-editor
  # (issue #1587): real fails the role's "Install Atom editor" task on a
  # Linux host with get_bin_path's "Failed to find required executable
  # \"brew\"" and stops the play (rc=2), while krikri skipped the task and
  # moved on (rc=4). Ported from community.general's
  # modules/homebrew_cask.py (11.x, same file on main).
  #
  # The community.general FQCN spelling stays deliberately unregistered
  # (KNOWN_MISSING.md's macOS-first limit for the brew roles) - only the
  # builtin spelling the core runtime redirects resolves here.
  class HomebrewCaskPlugin < BasePlugin
    DEFAULT_BREW_PATHS = "/usr/local/bin:/opt/homebrew/bin"

    # The argument spec's own choices, in its declaration order - the
    # wording is the argspec choices failure module setup raises before
    # main() runs, so it beats the brew lookup (`state: bogus` fails with
    # this text even on a host with no brew at all).
    STATE_CHOICES = %w[present installed latest upgraded absent removed uninstalled]

    # HomebrewValidate's VALID_PATH_CHARS complement (the `path:` value is
    # colon-split before validation, so a whole string is never checked).
    VALID_PATH_RE = /[^\w\s:.\/-]/

    # HomebrewValidate's VALID_BREW_PATH_CHARS complement.
    VALID_BREW_PATH_RE = /[^\w\s.\/-]/

    # HomebrewCask's VALID_CASK_CHARS complement: word chars, dots, slashes
    # (taps), dashes, at-signs, plusses.
    VALID_CASK_RE = /[^\w.\/\-@+]/

    @brew_path = ""
    @casks : Array(String)? = nil
    @state = "installed"
    @sudo_password : String? = nil
    @update_homebrew = false
    @accept_external_apps = false
    @upgrade_all = false
    @greedy = false
    @install_options = [] of String
    @current_cask = ""
    @brew_version : String? = nil
    @failed = false
    @changed = false
    @changed_count = 0
    @unchanged_count = 0
    @message = ""

    protected def bool_params : Array(String)
      %w[update_homebrew accept_external_apps upgrade_all greedy]
    end

    protected def bool_param_aliases : Hash(String, String)
      {"upgrade" => "upgrade_all"}
    end

    # The uncaught-exception failure shape (the path/brew_path setters'
    # HomebrewCaskException escaping main()): the module wrapper puts the
    # whole error chain INSIDE the result msg (where a fail_json result
    # stays bare), while the [ERROR] block is built from the bare detail
    # the engine picks up through _ansible_error_detail.
    private def crash_result(detail : String) : PluginResult
      PluginResult.new(changed: false, failed: true,
        msg: "Task failed: Module failed: #{detail}",
        _ansible_error_detail: detail)
    end

    def execute : PluginResult # ameba:disable Metrics/CyclomaticComplexity
      # Module setup (parameters.py) order: bool type conversion first,
      # then the state choices, then main()'s own logic.
      validate_bool_params!

      state_param = @params["state"]? || "present"
      unless STATE_CHOICES.includes?(state_param)
        return PluginResult.new(changed: false, failed: true,
          msg: "value of state must be one of: #{STATE_CHOICES.join(", ")}, got: #{state_param}")
      end

      # main()'s name handling: the argspec is `type: list` (aliases cask/
      # package/pkg), so Ansible's check_type_list has already split a
      # comma string - including an explicit empty one, which stays a
      # truthy [''] and installs an empty-named cask - while an absent or
      # null value is None. Unlike homebrew, the module does NOT lowercase
      # cask names.
      @casks = list_param("name", "pkg", "package", "cask")

      @state = case state_param
               when "present", "installed" then "installed"
               when "latest", "upgraded"   then "upgraded"
               else                             "absent" # absent/removed/uninstalled
               end

      @sudo_password = @params["sudo_password"]?.presence
      # update_homebrew is parsed and passed to the constructor but never
      # called by _run() in the real module - only _update_homebrew exists,
      # so a task setting it changes nothing. Kept as a parsed bool so its
      # type is still validated, exactly like real.
      @update_homebrew = true?(@params["update_homebrew"]?)
      @upgrade_all = true?(@params["upgrade_all"]?)
      @accept_external_apps = true?(@params["accept_external_apps"]?)
      @greedy = true?(@params["greedy"]?)
      @install_options = (list_param("install_options", "options") || [] of String).map { |opt| "--#{opt}" }

      # check_type_path's expanduser+expandvars (the module process's env,
      # i.e. the target's), then main()'s split and the path setter's
      # valid_path check - the HomebrewCaskException it raises escapes
      # main() uncaught, hence the crash shape rather than a fail_json.
      path_raw = expand_tilde(expand_vars(@params["path"]? || DEFAULT_BREW_PATHS))
      path_list = path_raw.split(':')
      if path_list.any? { |dir| dir.matches?(VALID_PATH_RE) }
        detail = "Invalid path: [#{path_list.map { |dir| "'#{dir}'" }.join(", ")}]."
        return crash_result(detail)
      end

      # _prep_brew_path: module.get_bin_path('brew', required=True,
      # opt_dirs=path) - existing opt_dirs first, then $PATH, then the
      # existing sbin dirs basic.py appends. The ValueError it raises when
      # brew is nowhere renders BARE in the result msg with the collapsed
      # chain only in the [ERROR] block - the plain fail_json shape.
      found, searched = find_brew(path_list)
      return PluginResult.new(changed: false, failed: true,
        msg: PluginHelpers::GetBinPath.missing_executable_error("brew", searched)) unless found

      # The brew_path setter's valid_brew_path check - same uncaught
      # HomebrewCaskException shape as the path setter.
      if found.matches?(VALID_BREW_PATH_RE)
        return crash_result("Invalid brew_path: #{found}.")
      end
      @brew_path = found

      begin
        run_flows
      rescue HomebrewCaskStop
        # run() catches HomebrewCaskException without touching the failed
        # flag - the check-mode "would be" exits land here with failed
        # still false and changed already set (exit_json, not fail_json).
      end

      # HomebrewCask.run's tail: a multi-cask result summarizes the counts
      # instead of carrying the last branch's message.
      if !@failed && (@changed_count + @unchanged_count > 1)
        @message = "Changed: #{@changed_count}, Unchanged: #{@unchanged_count}"
      end

      if @failed
        return PluginResult.new(changed: false, failed: true, msg: @message)
      end

      # exit_json(changed=..., msg=...) - main() passes msg explicitly, so
      # the key is always present.
      PluginResult.new(changed: @changed, failed: false, msg: @message, include_empty_msg: true)
    rescue ex : HomebrewCaskFailure
      # run() catches HomebrewCaskException and turns it into
      # fail_json(msg=message) - the bare-msg shape, never the crash shape
      # (the path/brew_path setters' raises above are the only ones that
      # escape main()). The tail's Changed/Unchanged summary is skipped on
      # a failure, exactly like run()'s `if not self.failed` guard.
      PluginResult.new(changed: false, failed: true, msg: ex.message.to_s)
    end

    # The `type: list` view of one option: absent or explicit null is nil
    # (Python None), anything present comma-splits the way check_type_list
    # does - an explicit empty string becomes [''], not [].
    private def list_param(*keys : String) : Array(String)?
      key = keys.find { |candidate| @params.has_key?(candidate) }
      return nil if key.nil?
      return nil if explicit_null_param?(key)
      @params[key].split(',')
    end

    private class HomebrewCaskFailure < Exception
    end

    private class HomebrewCaskStop < Exception
    end

    private def expand_vars(text : String) : String
      text.gsub(/\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/) do |token|
        ENV.fetch(token.lstrip('$').delete("{}"), "")
      end
    end

    # basic.py get_bin_path's search construction, on the target: existing
    # opt_dirs, then $PATH entries as-is (empties included in the reported
    # list, skipped in the search), then the existing sbin dirs basic.py
    # appends when not already present. Returns the resolved brew path (or
    # nil) plus the exact colon-joined list the ValueError reports.
    private def find_brew(opt_dirs : Array(String)) : {String?, String}
      dirs = opt_dirs.map { |dir| Process.quote(dir) }.join(" ")
      script = <<-SH
        found=""
        searched=""
        for d in #{dirs}; do
          [ -n "$d" ] || continue
          [ -e "$d" ] || continue
          searched="${searched:+$searched:}$d"
          if [ -z "$found" ] && [ -f "$d/brew" ] && [ -x "$d/brew" ]; then found="$d/brew"; fi
        done
        for d in $(printf '%s' "$PATH" | tr ':' ' '); do
          searched="${searched:+$searched:}$d"
          if [ -n "$d" ] && [ -z "$found" ] && [ -f "$d/brew" ] && [ -x "$d/brew" ]; then found="$d/brew"; fi
        done
        for d in /sbin /usr/sbin /usr/local/sbin; do
          case ":$searched:" in *":$d:"*) continue ;; esac
          [ -e "$d" ] || continue
          searched="${searched:+$searched:}$d"
          if [ -z "$found" ] && [ -f "$d/brew" ] && [ -x "$d/brew" ]; then found="$d/brew"; fi
        done
        printf '%s\\n%s' "$found" "$searched"
        SH

      result = remote_exec(script)
      found, _, searched = result[:stdout].to_s.partition("\n")
      found = found.strip
      searched = searched.strip
      {found.empty? ? nil : found, searched}
    end

    # module.run_command with the module's own
    # run_command_environ_update (LANG/LC_ALL/LC_MESSAGES/LC_CTYPE=C - note
    # this module sets LANG where homebrew.py sets LANGUAGE).
    private def run_command(argv : Array(String), environ : Hash(String, String) = {} of String => String) : {Int32, String, String}
      env = {"LANG" => "C", "LC_ALL" => "C", "LC_MESSAGES" => "C", "LC_CTYPE" => "C"}.merge(environ)
      prefix = "env " + env.map { |key, value| "#{key}=#{Process.quote(value)}" }.join(' ')
      cmd = "#{prefix} #{argv.map { |arg| Process.quote(arg) }.join(' ')}"
      result = remote_exec(cmd)
      {result[:exit_code], result[:stdout].to_s, result[:stderr].to_s}
    end

    private def check_mode? : Bool
      true?(@params["_ansible_check_mode"]?)
    end

    # check-mode "would be" exits: HomebrewCaskException raised with changed
    # already set and failed untouched - run()'s catch turns it into a
    # SUCCESS exit_json (a check-mode module never reports failed).
    private def stop_with(message : String) : NoReturn
      @message = message
      raise HomebrewCaskStop.new(message)
    end

    # Real failures set failed alongside the message; run()'s catch leaves
    # both intact and main() turns them into fail_json(msg=message).
    private def fail_with(message : String) : NoReturn
      @failed = true
      @message = message
      raise HomebrewCaskFailure.new(message)
    end

    private def run_flows : Nil
      if @upgrade_all
        upgrade_all_flow
        return
      end

      if casks = @casks
        case @state
        when "installed" then install_casks(casks)
        when "upgraded"  then upgrade_casks(casks)
        when "absent"    then uninstall_casks(casks)
        else                  fail_with("You must select a cask to install.")
        end
        return
      end

      fail_with("You must select a cask to install.")
    end

    # The current_cask setter: an invalid name sets failed+message and
    # raises before any brew command runs.
    private def set_current_cask(cask : String) : Nil
      unless valid_cask?(cask)
        @failed = true
        @message = "Invalid cask: #{cask}."
        raise HomebrewCaskFailure.new(@message)
      end
      @current_cask = cask
    end

    private def valid_cask?(cask : String) : Bool
      !cask.matches?(VALID_CASK_RE)
    end

    # _brew_cask_command_is_deprecated: `brew cask ...` was folded into the
    # main command in Homebrew 2.6.0, so newer brews use `--cask` flags.
    private def brew_cask_command_is_deprecated? : Bool
      version_at_least?(get_brew_version, "2.6.0")
    end

    private def get_brew_version : String
      if version = @brew_version
        return version
      end

      rc, out, err = run_command([@brew_path, "--version"])
      # run_command(check_rc=True) fails the module with the stripped
      # stderr as msg before this module ever parses the output.
      if rc != 0
        fail_with(err.rstrip)
      end

      match = out.match(/Homebrew (.*)(\d+\.\d+\.\d+)(-dirty)?/)
      unless match
        fail_with("Failed to match regex to get brew version")
      end
      version = match[2]
      @brew_version = version
      version
    end

    # LooseVersion(a) >= LooseVersion(b): numeric components compared in
    # order, non-numeric tails ignored (Homebrew versions are dotted ints).
    private def version_at_least?(version : String, minimum : String) : Bool
      left = version.scan(/\d+/).map(&.[0].to_i)
      right = minimum.scan(/\d+/).map(&.[0].to_i)
      right.size.times do |index|
        current = left[index]? || 0
        return false if current < right[index]
        return true if current > right[index]
      end
      true
    end

    private def current_cask_is_installed? : Bool
      unless valid_cask?(@current_cask)
        @failed = true
        @message = "Invalid cask: #{@current_cask}."
        raise HomebrewCaskFailure.new(@message)
      end

      base = brew_cask_command_is_deprecated? ? [@brew_path, "list", "--cask"] : [@brew_path, "cask", "list"]
      result = run_command(base + [@current_cask])
      result[0] == 0
    end

    private def current_cask_is_outdated? : Bool
      return false unless valid_cask?(@current_cask)

      base = brew_cask_command_is_deprecated? ? [@brew_path, "outdated", "--cask"] : [@brew_path, "cask", "outdated"]
      cmd = base + (@greedy ? ["--greedy"] : [] of String) + [@current_cask]
      _, out, _ = run_command(cmd)
      !out.empty?
    end

    # sudo_password: run_command with SUDO_ASKPASS pointing at a throwaway
    # askpass script, exactly as the module does (add_cleanup_file's
    # deletion happens here in an ensure).
    private def run_command_with_sudo_password(argv : Array(String)) : {Int32, String, String}
      temp = File.tempfile("ansible-sudo-askpass")
      begin
        temp.print("#!/bin/sh\n\necho '#{@sudo_password}'\n")
        temp.close
        File.chmod(temp.path, 0o700)
        run_command(argv, {"SUDO_ASKPASS" => temp.path})
      ensure
        File.delete?(temp.path)
      end
    end

    private def run_cask_command(argv : Array(String)) : {Int32, String, String}
      if @sudo_password
        run_command_with_sudo_password(argv)
      else
        run_command(argv)
      end
    end

    private def upgrade_all_flow : Nil
      if check_mode?
        @changed = true
        stop_with("Casks would be upgraded.")
      end

      cmd = brew_cask_command_is_deprecated? ? [@brew_path, "upgrade", "--cask"] : [@brew_path, "cask", "upgrade"]
      cmd += ["--greedy"] if @greedy

      rc, out, err = run_cask_command(cmd)
      if rc == 0
        # `brew upgrade --cask` prints nothing when nothing was upgraded.
        text = out.strip
        if text.empty? || text.matches?(/==> No Casks to upgrade/i)
          @message = "Homebrew casks already upgraded."
        else
          @changed = true
          @message = "Homebrew casks upgraded."
        end
      else
        fail_with(err.strip)
      end
    end

    private def install_casks(casks : Array(String)) : Nil
      casks.each do |cask|
        set_current_cask(cask)
        install_current_cask
      end
    end

    private def install_current_cask : Nil
      unless valid_cask?(@current_cask)
        @failed = true
        @message = "Invalid cask: #{@current_cask}."
        raise HomebrewCaskFailure.new(@message)
      end

      if !@install_options.includes?("--force") && current_cask_is_installed?
        @unchanged_count += 1
        @message = "Cask already installed: #{@current_cask}"
        return
      end

      if check_mode?
        @changed = true
        stop_with("Cask would be installed: #{@current_cask}")
      end

      base = brew_cask_command_is_deprecated? ? [@brew_path, "install", "--cask"] : [@brew_path, "cask", "install"]
      cmd = (base + [@current_cask] + @install_options).reject(&.empty?)

      _, _, err = run_cask_command(cmd)
      if current_cask_is_installed?
        @changed_count += 1
        @changed = true
        @message = "Cask installed: #{@current_cask}"
      elsif @accept_external_apps && err.includes?("Error: It seems there is already an App at")
        @unchanged_count += 1
        @message = "Cask already installed: #{@current_cask}"
      else
        fail_with(err.strip)
      end
    end

    private def upgrade_casks(casks : Array(String)) : Nil
      casks.each do |cask|
        set_current_cask(cask)
        upgrade_current_cask
      end
    end

    private def upgrade_current_cask : Nil
      command = "upgrade"

      unless valid_cask?(@current_cask)
        @failed = true
        @message = "Invalid cask: #{@current_cask}."
        raise HomebrewCaskFailure.new(@message)
      end

      command = "install" unless current_cask_is_installed?

      if current_cask_is_installed? && !current_cask_is_outdated?
        @message = "Cask is already upgraded: #{@current_cask}"
        @unchanged_count += 1
        return
      end

      if check_mode?
        @changed = true
        stop_with("Cask would be upgraded: #{@current_cask}")
      end

      base = brew_cask_command_is_deprecated? ? [@brew_path, command, "--cask"] : [@brew_path, "cask", command]
      cmd = (base + @install_options + [@current_cask]).reject(&.empty?)

      _, _, err = run_cask_command(cmd)
      if current_cask_is_installed? && !current_cask_is_outdated?
        @changed_count += 1
        @changed = true
        @message = "Cask upgraded: #{@current_cask}"
      else
        fail_with(err.strip)
      end
    end

    private def uninstall_casks(casks : Array(String)) : Nil
      casks.each do |cask|
        set_current_cask(cask)
        uninstall_current_cask
      end
    end

    private def uninstall_current_cask : Nil
      unless valid_cask?(@current_cask)
        @failed = true
        @message = "Invalid cask: #{@current_cask}."
        raise HomebrewCaskFailure.new(@message)
      end

      unless current_cask_is_installed?
        @unchanged_count += 1
        @message = "Cask already uninstalled: #{@current_cask}"
        return
      end

      if check_mode?
        @changed = true
        stop_with("Cask would be uninstalled: #{@current_cask}")
      end

      base = brew_cask_command_is_deprecated? ? [@brew_path, "uninstall", "--cask"] : [@brew_path, "cask", "uninstall"]
      cmd = (base + [@current_cask] + @install_options).reject(&.empty?)

      _, _, err = run_cask_command(cmd)
      if !current_cask_is_installed?
        @changed_count += 1
        @changed = true
        @message = "Cask uninstalled: #{@current_cask}"
      else
        fail_with(err.strip)
      end
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::HomebrewCaskPlugin.new(config)
plugin.run
