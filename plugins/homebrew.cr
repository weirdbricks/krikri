#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # ansible.builtin.homebrew - macOS Homebrew package management.
  #
  # ansible-core's own builtin runtime redirects the ansible.builtin
  # spelling to community.general.homebrew and RUNS it (live-verified vs
  # 2.19.11), so before this plugin the graceful unavailable-module skip
  # diverged on rooland-provisioning.git-gpg (issue #777): real fails the
  # role's "Install packages" task on a Linux host with get_bin_path's
  # "Failed to find required executable \"brew\"" and stops the play
  # (rc=2), while krikri skipped the items and moved on to the next task
  # (rc=4). Ported from community.general's modules/homebrew.py (11.x,
  # same file on main).
  #
  # The community.general FQCN spelling stays deliberately unregistered
  # (KNOWN_MISSING.md's macOS-first limit for the linuxbrew roles) - only
  # the builtin spelling the core runtime redirects resolves here.
  class HomebrewPlugin < BasePlugin
    DEFAULT_BREW_PATHS = "/usr/local/bin:/opt/homebrew/bin:/home/linuxbrew/.linuxbrew/bin"

    # The argument spec's own choices, in its declaration order - the
    # wording (live-verified vs 2.19.11) is the argspec choices failure
    # the module setup raises before main() runs, so it beats the brew
    # lookup: `state: bogus` fails with this text even on a host with no
    # brew at all.
    STATE_CHOICES = %w[present installed latest upgraded head linked unlinked absent removed uninstalled]

    # HomebrewValidate's VALID_PACKAGE_CHARS complement: word chars, dots,
    # slashes (taps), plusses, dashes, colons (URLs), at-signs.
    VALID_PACKAGE_RE = /[^\w.\/+:@\-]/

    # HomebrewValidate's VALID_BREW_PATH_CHARS complement: word chars,
    # whitespace, slashes, dots, dashes - no colons (the `path:` value is
    # colon-split before validation, so components never carry one).
    VALID_BREW_PATH_RE = /[^\w\s.\/\-]/

    @brew_path = ""
    @packages : Array(String)? = nil
    @state = "installed"
    @update_homebrew = false
    @upgrade_all = false
    @install_options = [] of String
    @upgrade_options = [] of String
    @force_formula = false
    @failed = false
    @changed = false
    @message = ""
    @changed_pkgs = [] of String
    @unchanged_pkgs = [] of String
    @installed_packages = [] of String
    @outdated_packages = [] of String

    protected def bool_params : Array(String)
      %w[update_homebrew upgrade_all force_formula]
    end

    protected def bool_param_aliases : Hash(String, String)
      {"upgrade" => "upgrade_all"}
    end

    # The uncaught-exception failure shape (live-verified vs 2.19.11, the
    # path setter's HomebrewException escaping main()): the module wrapper
    # puts the whole error chain INSIDE the result msg (where a fail_json
    # result stays bare), while the [ERROR] block is built from the bare
    # detail the engine picks up through _ansible_error_detail.
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

      # main()'s name handling: aliases resolve to `name`, a non-empty
      # value comma-splits into the (lowercased) package list, and an
      # empty/absent one leaves packages nil - no package work at all.
      name_raw = @params["name"]? || @params["pkg"]? || @params["package"]? || @params["formula"]?
      @packages = (name_raw.nil? || name_raw.empty?) ? nil : name_raw.split(',').map(&.downcase)

      @state = case state_param
               when "present", "installed" then "installed"
               when "head"                 then "head"
               when "latest", "upgraded"   then "upgraded"
               when "linked"               then "linked"
               when "unlinked"             then "unlinked"
               else                             "absent" # absent/removed/uninstalled
               end

      @update_homebrew = true?(@params["update_homebrew"]?)
      @upgrade_all = true?(@params["upgrade_all"]?)
      @force_formula = true?(@params["force_formula"]?)
      @install_options = (@params["install_options"]? || @params["options"]?).to_s.split(',').reject(&.empty?).map { |opt| "--#{opt}" }
      @upgrade_options = @params["upgrade_options"]?.to_s.split(',').reject(&.empty?).map { |opt| "--#{opt}" }

      # check_type_path's expanduser+expandvars (the module process's env,
      # i.e. the target's), then the path setter's valid_path check - the
      # HomebrewException it raises escapes main() uncaught, hence the
      # crash shape rather than a fail_json.
      path_raw = expand_tilde(expand_vars(@params["path"]? || DEFAULT_BREW_PATHS))
      path_list = path_raw.split(':')
      if path_list.any? { |dir| dir.matches?(VALID_BREW_PATH_RE) }
        detail = "Invalid path: [#{path_list.map { |dir| "'#{dir}'" }.join(", ")}]."
        return crash_result(detail)
      end

      # _prep_brew_path: module.get_bin_path('brew', required=True,
      # opt_dirs=path) - existing opt_dirs first, then $PATH, then the
      # existing sbin dirs basic.py appends. The ValueError it raises when
      # brew is nowhere renders BARE in the result msg (live-verified vs
      # 2.19.11) with the collapsed chain only in the [ERROR] block - the
      # plain fail_json shape, unlike the crash shape above.
      found, searched = find_brew(path_list)
      return PluginResult.new(changed: false, failed: true,
        msg: PluginHelpers::GetBinPath.missing_executable_error("brew", searched)) unless found

      # The brew_path setter's valid_brew_path check - same uncaught
      # HomebrewException shape as the path setter.
      unless valid_brew_path?(found)
        return crash_result("Invalid brew_path: #{found}.")
      end
      @brew_path = found

      begin
        run_flows
      rescue HomebrewStop
        # run() catches HomebrewException without touching the failed flag -
        # the check-mode "would be" exits land here with failed still false
        # and changed already set (exit_json, not fail_json).
      end

      # Homebrew.run's tail: a multi-package result summarizes the counts
      # instead of carrying the last branch's message.
      if !@failed && (@changed_pkgs.size + @unchanged_pkgs.size > 1)
        @message = "Changed: #{@changed_pkgs.size}, Unchanged: #{@unchanged_pkgs.size}"
      end

      if @failed
        return PluginResult.new(changed: false, failed: true, msg: @message)
      end

      # exit_json(changed=..., msg=..., unchanged_pkgs=..., changed_pkgs=...)
      # - the msg key is always present (an empty one included) because
      # main() passes it explicitly.
      PluginResult.new(changed: @changed, failed: false, msg: @message, include_empty_msg: true,
        key_order: %w[changed msg unchanged_pkgs changed_pkgs],
        unchanged_pkgs: @unchanged_pkgs, changed_pkgs: @changed_pkgs)
    rescue ex : HomebrewFailure
      # run() catches HomebrewException and turns it into fail_json(msg=...)
      # - the bare-msg shape, never the crash shape (the path/brew_path
      # setters' raises above are the only ones that escape main()). The
      # tail's Changed/Unchanged summary is skipped on a failure, exactly
      # like run()'s `if not self.failed` guard.
      PluginResult.new(changed: false, failed: true, msg: ex.message.to_s)
    end

    private class HomebrewFailure < Exception
    end

    private class HomebrewStop < Exception
    end

    private def expand_vars(text : String) : String
      text.gsub(/\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/) do |token|
        ENV.fetch(token.lstrip('$').delete("{}"), "")
      end
    end

    private def valid_brew_path?(path : String) : Bool
      !path.matches?(VALID_BREW_PATH_RE)
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

    # run_command with the module's own environ update: LANGUAGE/LC_ALL
    # always (module.run_command_environ_update), plus
    # HOMEBREW_NO_AUTO_UPDATE=True unless update_homebrew was requested -
    # without it brew auto-updates on every install and the module's
    # update_homebrew bookkeeping would misreport changed.
    private def run_brew(argv : Array(String)) : {Int32, String, String}
      env_prefix = "env LANGUAGE=C LC_ALL=C"
      env_prefix += " HOMEBREW_NO_AUTO_UPDATE=True" unless @update_homebrew
      cmd = "#{env_prefix} #{argv.map { |arg| Process.quote(arg) }.join(' ')}"
      result = remote_exec(cmd)
      {result[:exit_code], result[:stdout].to_s, result[:stderr].to_s}
    end

    private def check_mode? : Bool
      true?(@params["_ansible_check_mode"]?)
    end

    # check-mode "would be" exits: HomebrewException raised with changed
    # already set and failed untouched - run()'s catch turns it into a
    # SUCCESS exit_json (a check-mode module never reports failed).
    private def stop_with(message : String) : NoReturn
      @message = message
      raise HomebrewStop.new(message)
    end

    # Real failures set failed alongside the message; run()'s catch leaves
    # both intact and main() turns them into fail_json(msg=message).
    private def fail_with(message : String) : NoReturn
      @failed = true
      @message = message
      raise HomebrewFailure.new(message)
    end

    private def run_flows : Nil
      if @update_homebrew
        update_homebrew_flow
      end

      if @upgrade_all
        upgrade_all_flow
      end

      if packages = @packages
        return if packages.empty?

        validate_package_names(packages)
        get_packages_info(packages)

        case @state
        when "installed", "head" then install_packages(packages)
        when "upgraded"          then upgrade_packages(packages)
        when "linked"            then link_packages(packages)
        when "unlinked"          then unlink_packages(packages)
        when "absent"            then uninstall_packages(packages)
        end
      end
    end

    private def update_homebrew_flow : Nil
      if check_mode?
        @changed = true
        stop_with("Homebrew would be updated.")
      end

      rc, brew_out, err = run_brew([@brew_path, "update"])
      if rc == 0
        unless brew_out.empty?
          already = brew_out.split('\n').any? { |line| !(line.strip =~ /Already up-to-date./i).nil? }
          if already
            @message = "Homebrew already up-to-date."
          else
            @changed = true
            @message = "Homebrew updated successfully."
          end
        end
      else
        fail_with(err.strip)
      end
    end

    private def upgrade_all_flow : Nil
      if check_mode?
        @changed = true
        stop_with("Homebrew packages would be upgraded.")
      end

      rc, brew_out, err = run_brew([@brew_path, "upgrade"] + @upgrade_options)
      if rc == 0
        if brew_out.empty?
          @message = "Homebrew packages already upgraded."
        else
          @changed = true
          @message = "Homebrew upgraded."
        end
      else
        fail_with(err.strip)
      end
    end

    # HomebrewValidate.valid_package - an invalid name fails BEFORE the
    # brew info probe (but AFTER the brew lookup, which happens in the
    # constructor).
    private def validate_package_names(packages : Array(String)) : Nil
      invalid = packages.select { |package| package.matches?(VALID_PACKAGE_RE) }
      return if invalid.empty?

      word = invalid.size > 1 ? "packages" : "package"
      fail_with("Invalid #{word}: #{invalid.join(", ")}")
    end

    private def get_packages_info(packages : Array(String)) : Nil
      argv = [@brew_path, "info", "--json=v2"] + packages.dup
      argv << "--formula" if @force_formula
      rc, brew_out, err = run_brew(argv)
      if rc != 0
        text = err.strip
        fail_with(text.empty? ? "Unknown failure with exit code #{rc}" : text)
      end

      data = JSON.parse(brew_out)
      formulae = data["formulae"]?.try(&.as_a?) || [] of JSON::Any
      formulae.each do |detail|
        package_name = extract_package_name(detail, packages, cask: false)
        save_package_info(detail, package_name)
      end
      casks = data["casks"]?.try(&.as_a?) || [] of JSON::Any
      casks.each do |detail|
        package_name = extract_package_name(detail, packages, cask: true)
        save_package_info(detail, package_name)
      end
    end

    # _extract_package_name: the user-supplied name must resurface from
    # the brew info detail's name/full_name (token/full_token for casks),
    # its aliases/oldnames/old_tokens, and their tap-prefixed forms - and
    # do so uniquely.
    private def extract_package_name(detail : JSON::Any, packages : Array(String), cask : Bool) : String
      primary = cask ? detail["token"]?.try(&.as_s?) : detail["name"]?.try(&.as_s?)
      full = cask ? detail["full_token"]?.try(&.as_s?) : detail["full_name"]?.try(&.as_s?)
      primary ||= ""
      full ||= ""

      names = [primary, full]
      {"aliases", "oldnames", "old_tokens"}.each do |key|
        extras = detail[key]?.try(&.as_a?)
        extras.try(&.each { |extra| names << extra.as_s })
      end
      if tap = detail["tap"]?.try(&.as_s?)
        names += names.map { |name| "#{tap}/#{name}" }
      end

      matches = [] of String
      names.each do |name|
        matches << name if packages.includes?(name) && !matches.includes?(name)
      end
      return matches[0] if matches.size == 1

      fail_with("Package names for #{primary} are missing or ambiguous: #{matches.join(", ")}")
    end

    private def save_package_info(detail : JSON::Any, package_name : String) : Nil
      @installed_packages << package_name if python_truthy?(detail["installed"]?)
      @outdated_packages << package_name if python_truthy?(detail["outdated"]?)
    end

    # bool(detail.get(key)): a non-empty list/true is truthy, everything
    # else (absent, null, false, empty list) is not.
    private def python_truthy?(value : JSON::Any?) : Bool
      case raw = value.try(&.raw)
      when Bool  then raw
      when Array then !raw.empty?
      else            false
      end
    end

    private def install_packages(packages : Array(String)) : Nil
      to_install = packages.reject { |package| @installed_packages.includes?(package) }

      if to_install.empty?
        @unchanged_pkgs.concat(packages)
        @message = "#{pkg_word(packages.size)} already installed: #{packages.join(", ")}"
        return
      end

      if check_mode?
        @changed = true
        stop_with("#{pkg_word(to_install.size)} would be installed: #{to_install.join(", ")}")
      end

      argv = [@brew_path, "install"] + @install_options + to_install
      argv << "--HEAD" if @state == "head"
      argv << "--formula" if @force_formula
      rc, _, err = run_brew(argv)
      if rc == 0
        @changed_pkgs.concat(to_install)
        @unchanged_pkgs.concat(@installed_packages)
        @changed = true
        @message = "#{pkg_word(to_install.size)} installed: #{to_install.join(", ")}"
      else
        fail_with(err.strip)
      end
    end

    private def upgrade_packages(packages : Array(String)) : Nil
      if packages.empty?
        upgrade_all_packages
        return
      end

      # Three actions: not installed -> install, installed and outdated ->
      # upgrade, installed and current -> nothing to do.
      to_install = packages.reject { |package| @installed_packages.includes?(package) }
      to_upgrade = @installed_packages.select { |package| @outdated_packages.includes?(package) }
      touched = (to_install + to_upgrade).uniq

      if touched.empty?
        @unchanged_pkgs.concat(packages)
        @message = "#{pkg_word(packages.size)} already upgraded: #{packages.join(", ")}"
        return
      end

      if check_mode?
        @changed = true
        stop_with("#{pkg_word(touched.size)} would be upgraded: #{touched.join(", ")}")
      end

      {"install" => to_install, "upgrade" => to_upgrade}.each do |command, list|
        next if list.empty?

        rc, _, err = run_brew([@brew_path, command] + @install_options + list)
        if rc != 0
          fail_with(err.strip)
        end
      end

      @changed_pkgs.concat(touched)
      @unchanged_pkgs.concat(packages.reject { |package| touched.includes?(package) })
      @changed = true
      @message = "#{pkg_word(touched.size)} upgraded: #{touched.join(", ")}"
    end

    private def upgrade_all_packages : Nil
      rc, _, err = run_brew([@brew_path, "upgrade"] + @install_options)
      if rc == 0
        @changed = true
        @message = "All packages upgraded."
      else
        fail_with(err.strip)
      end
    end

    private def uninstall_packages(packages : Array(String)) : Nil
      to_uninstall = @installed_packages.select { |package| packages.includes?(package) }

      if to_uninstall.empty?
        @unchanged_pkgs.concat(packages)
        @message = "#{pkg_word(packages.size)} already uninstalled: #{packages.join(", ")}"
        return
      end

      if check_mode?
        @changed = true
        stop_with("#{pkg_word(to_uninstall.size)} would be uninstalled: #{to_uninstall.join(", ")}")
      end

      rc, _, err = run_brew([@brew_path, "uninstall", "--force"] + @install_options + to_uninstall)
      if rc == 0
        @changed_pkgs.concat(to_uninstall)
        @unchanged_pkgs.concat(packages.reject { |package| @installed_packages.includes?(package) })
        @changed = true
        @message = "#{pkg_word(to_uninstall.size)} uninstalled: #{to_uninstall.join(", ")}"
      else
        fail_with(err.strip)
      end
    end

    private def link_packages(packages : Array(String)) : Nil
      missing = packages.reject { |package| @installed_packages.includes?(package) }
      unless missing.empty?
        fail_with("#{pkg_word(missing.size)} not installed: #{missing.join(", ")}.")
      end

      if check_mode?
        @changed = true
        stop_with("#{pkg_word(packages.size)} would be linked: #{packages.join(", ")}")
      end

      rc, _, _ = run_brew([@brew_path, "link"] + @install_options + packages)
      if rc == 0
        @changed_pkgs.concat(packages)
        @changed = true
        @message = "#{pkg_word(packages.size)} linked: #{packages.join(", ")}"
      else
        fail_with("#{pkg_word(packages.size)} could not be linked: #{packages.join(", ")}.")
      end
    end

    private def unlink_packages(packages : Array(String)) : Nil
      missing = packages.reject { |package| @installed_packages.includes?(package) }
      unless missing.empty?
        fail_with("#{pkg_word(missing.size)} not installed: #{missing.join(", ")}.")
      end

      if check_mode?
        @changed = true
        stop_with("#{pkg_word(packages.size)} would be unlinked: #{packages.join(", ")}")
      end

      rc, _, _ = run_brew([@brew_path, "unlink"] + @install_options + packages)
      if rc == 0
        @changed_pkgs.concat(packages)
        @changed = true
        @message = "#{pkg_word(packages.size)} unlinked: #{packages.join(", ")}"
      else
        fail_with("#{pkg_word(packages.size)} could not be unlinked: #{packages.join(", ")}.")
      end
    end

    private def pkg_word(count : Int32) : String
      count > 1 ? "Packages" : "Package"
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::HomebrewPlugin.new(config)
plugin.run
