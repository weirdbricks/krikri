#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # Alternatives plugin - manages symlinks via `update-alternatives`.
  # Compatible with (a subset of) community.general.alternatives.
  #
  # Entirely unimplemented before - robertdebock.alternatives' own
  # "Configure alternatives" task (community.general.alternatives)
  # silently dropped while Ansible actually ran update-alternatives.
  #
  # Debian/Ubuntu (`update-alternatives`) only - `family:` is RHEL-only
  # and not supported (no RHEL host available to verify against).
  class AlternativesPlugin < BasePlugin
    # One alternative as `update-alternatives --display` reports it
    # (alternatives.py's parse(): the regex's family group is the empty
    # string on Debian, where --display never prints one - Python's
    # findall yields "" for a group that never participated - and a real
    # family name on RHEL - the module compares it verbatim against
    # `family:`).
    alias Subcommand = NamedTuple(name: String, path: String, link: String?)

    alias Alternative = NamedTuple(priority: Int32, family: String?, subcommands: Array(Subcommand))

    # Ansible's `module.get_bin_path("update-alternatives", True)`, resolved
    # through the UPDATE_ALTERNATIVES property - lazily, so the first
    # call is parse()'s `--display`. The absolute path it resolves to is
    # also what the `cmd` of any run_command failure reads back.
    @update_alternatives : String? = nil

    # community.general.alternatives builds its result as
    # `dict(changed=False, diff=dict(before=dict(), after=dict()))` before
    # run() and only fills the two sides in when `module._diff` is set, so
    # a run without --diff still reports the empty pair (`--diff` is how
    # krikri-playbook-generator spotted the divergence: Ansible printed a
    # `--- before` / `+++ after` block on every changed loop item, krikri
    # printed none).
    @diff_before = {} of String => JSON::Any
    @diff_after = {} of String => JSON::Any

    def execute : PluginResult
      name = @params["name"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: name") unless name

      # AnsibleModule init order: required-args, then choices, then
      # required_one_of - all before the update-alternatives binary is
      # ever resolved by parse().
      state = @params["state"]? || "selected"
      unless ["present", "selected", "absent", "auto"].includes?(state)
        return PluginResult.new(changed: false, failed: true,
          msg: "value of state must be one of: present, selected, absent, auto, got: #{state}")
      end

      path = @params["path"]?
      family = @params["family"]?
      unless path || family
        return PluginResult.new(changed: false, failed: true,
          msg: "one of the following is required: path, family")
      end

      link = @params["link"]?
      priority_param = @params["priority"]?.try(&.to_i)
      subcommands = @params["subcommands"]?.try { |str| Array(JSON::Any).from_json(str) }
      check_mode = true?(@params["_ansible_check_mode"]?)

      unless bin = resolve_update_alternatives
        return PluginResult.new(changed: false, failed: true,
          msg: missing_executable_message("update-alternatives"))
      end

      current_mode, current_path, current_link, current_alternatives = parse_display(bin, name, path, subcommands)

      mode_present = ["present", "selected", "auto"].includes?(state)
      messages = [] of String

      if mode_present
        effective_link = link || current_link
        early = install_alternative_if_needed(bin, name, path, family, effective_link, priority_param, subcommands, current_alternatives, messages, check_mode)
        return early if early

        late = select_or_auto(bin, state, name, path, family, current_path, current_mode, current_alternatives, messages, check_mode)
        return late if late
      else
        late = remove_alternative(bin, name, path, current_alternatives, messages, check_mode)
        return late if late
      end

      # Real community.general.alternatives: result = dict(changed=False,
      # diff=...) then msg appended (alternatives.py:165,231) - live-verified
      # against Ansible 2.19.11 via a registered {{ r | to_json }} dump in the
      # podman container (check mode, changed and unchanged runs identical).
      PluginResult.new(changed: !messages.empty?, failed: false, msg: messages.join(' '), key_order: ["changed", "diff", "msg"],
        diff: JSON::Any.new({
          "before" => JSON::Any.new(@diff_before),
          "after"  => JSON::Any.new(@diff_after),
        }))
    end

    # Install the alternative for path when it's missing or its priority
    # changed. Returns the failure result when the path doesn't exist,
    # the link needed to install is missing, or update-alternatives
    # rejects the install; nil otherwise.
    #
    # Real gates the whole branch on `self.path is not None and (...)`,
    # so a family-only invocation never installs (alternatives.py run()).
    private def install_alternative_if_needed(bin : String, name : String, path : String?, family : String?, effective_link : String?, priority_param : Int32?, subcommands : Array(JSON::Any)?, current_alternatives : Hash(String, Alternative), messages : Array(String), check_mode : Bool) : PluginResult?
      return nil unless path
      current = current_alternatives[path]?
      needs_install = current.nil? || (priority_param && current[:priority] != priority_param)
      return nil unless needs_install

      # Real install() validates the path's existence before the link
      # (install() runs on the parsed current state, check mode included).
      unless remote_file_exists?(path)
        return PluginResult.new(changed: false, failed: true, msg: "Specified path #{path} does not exist")
      end
      unless effective_link
        return PluginResult.new(changed: false, failed: true, msg: "Needed to install the alternative, but unable to do so as we are missing the link")
      end
      priority = priority_param || current.try(&.[:priority]) || 50
      argv = [bin, "--install", effective_link, name, path, priority.to_s]
      argv += ["--family", family] if family
      if subcommands
        subcommands.each do |str|
          argv += ["--slave", str["link"].as_s, str["name"].as_s, str["path"].as_s]
        end
      end
      # The message records the change in BOTH modes - check mode only
      # skips the RUN, not the changed reporting (this used to append
      # only in check mode, so every real mutation reported changed:
      # false - found via CyVerse-Ansible.ansible_go round 1200072,
      # where real's cold run marked the go/gofmt installs changed and
      # krikri answered ok on the identical fresh host).
      messages << "Install alternative '#{path}' for '#{name}'."
      install_after_diff(path, family, priority, effective_link, subcommands, current)
      return run_check_rc(argv) unless check_mode
      nil
    end

    # state: selected - point the alternative at path, or at family when
    # only `family:` was given (Ansible's set(): "path takes precedence over
    # family as it is more specific"); state: auto - switch it back to
    # auto mode. Returns the failure result when update-alternatives
    # rejects the command.
    #
    # The gate is Ansible's `not (is_same_path or is_same_family)`, NOT a
    # `path &&` guard: with only `family:` given, self.path is None so
    # is_same_path is always false and Ansible still runs
    # `--set <name> <family>`.
    private def select_or_auto(bin : String, state : String, name : String, path : String?, family : String?, current_path : String?, current_mode : String?, current_alternatives : Hash(String, Alternative), messages : Array(String), check_mode : Bool) : PluginResult?
      is_same_path = !path.nil? && current_path == path
      is_same_family = !current_path.nil? && current_alternatives.has_key?(current_path) &&
                       current_alternatives[current_path][:family] == family

      if state == "selected" && !(is_same_path || is_same_family)
        arg = path || family
        argv = [bin, "--set", name, arg.to_s]
        messages << "Set alternative '#{arg}' for '#{name}'."
        set_after_state("selected")
        return run_check_rc(argv) unless check_mode
      end

      if state == "auto" && current_mode == "manual"
        argv = [bin, "--auto", name]
        messages << "Set alternative to auto for '#{name}'."
        set_after_state("present")
        return run_check_rc(argv) unless check_mode
      end

      nil
    end

    # Real's set()/auto() each touch only the state key, so a run with no
    # install() before it leaves the rest of `after` empty.
    private def set_after_state(state : String) : Nil
      @diff_after["state"] = JSON::Any.new(state) if diff_mode?
    end

    # state: absent - remove the alternative for path when it exists
    private def remove_alternative(bin : String, name : String, path : String?, current_alternatives : Hash(String, Alternative), messages : Array(String), check_mode : Bool) : PluginResult?
      return nil unless path && current_alternatives.has_key?(path)

      argv = [bin, "--remove", name, path]
      messages << "Remove alternative '#{path}' from '#{name}'."
      @diff_after = {"state" => JSON::Any.new("absent")} if diff_mode?
      return run_check_rc(argv) unless check_mode
      nil
    end

    # Real install() replaces the after side wholesale and adds
    # `subcommands` only when its own property is truthy - the task's
    # `subcommands:` when given, otherwise the ones the already-registered
    # path carries (a priority-only reinstall keeps them).
    private def install_after_diff(path : String, family : String?, priority : Int32, link : String?, subcommands : Array(JSON::Any)?, current : Alternative?) : Nil
      return unless diff_mode?
      @diff_after = {
        "state"    => JSON::Any.new("present"),
        "path"     => JSON::Any.new(path),
        "family"   => json_or_null(family),
        "priority" => JSON::Any.new(priority),
        "link"     => json_or_null(link),
      }
      effective = subcommands
      if effective.nil? && (alt = current) && !alt[:subcommands].empty?
        effective = alt[:subcommands].map { |sub| subcommand_json(sub) }
      end
      @diff_after["subcommands"] = JSON::Any.new(effective) if effective && !effective.empty?
    end

    private def subcommand_json(sub : Subcommand) : JSON::Any
      JSON::Any.new({
        "link" => json_or_null(sub[:link]),
        "name" => JSON::Any.new(sub[:name]),
        "path" => JSON::Any.new(sub[:path]),
      })
    end

    private def json_or_null(value : String?) : JSON::Any
      value ? JSON::Any.new(value) : JSON::Any.new(nil)
    end

    # The update-alternatives absolute path (get_bin_path), resolved once
    # on the target so every `cmd` Ansible reports names the same binary.
    private def resolve_update_alternatives : String?
      return @update_alternatives if @update_alternatives
      resolved = remote_exec("command -v update-alternatives 2>/dev/null")[:stdout].strip
      return nil if resolved.empty?
      @update_alternatives = resolved
    end

    # run_command(..., check_rc=True) - every update-alternatives call
    # real makes uses it, so a non-zero rc is basic.py's own failure: msg
    # is the bare rstripped stderr (never a "Failed to ..." label), and
    # cmd/rc/stdout/stderr plus the controller-derived *_lines ride
    # along. `cmd` renders the argv the way _clean_args does - shlex.quote
    # per token, spaces between; Shell.quote_arg leaves an already-safe
    # token bare exactly like shlex.quote does.
    private def run_check_rc(argv : Array(String)) : PluginResult?
      result = remote_exec(argv.map { |arg| shell_quote(arg) }.join(' '))
      return nil if result[:exit_code] == 0

      PluginResult.new(changed: false, failed: true, msg: result[:stderr].rstrip,
        cmd: argv.map { |arg| Shell.quote_arg(arg) }.join(' '), rc: result[:exit_code],
        stdout: result[:stdout], stdout_lines: result[:stdout].lines.map(&.chomp),
        stderr: result[:stderr], stderr_lines: result[:stderr].lines.map(&.chomp))
    end

    private def parse_display(bin : String, name : String, path : String?, subcommands : Array(JSON::Any)?) : {String?, String?, String?, Hash(String, Alternative)}
      result = remote_exec("#{shell_quote(bin)} --display #{shell_quote(name)}")
      current_alternatives = {} of String => Alternative
      # Real's parse() returns before it gets to the diff section when
      # `--display` exits non-zero (a name with no registered alternative
      # yet), so `before` stays the empty dict in that case - that is the
      # `{}` Ansible prints for the first install on a fresh host.
      return {nil, nil, nil, current_alternatives} unless result[:exit_code] == 0

      output = result[:stdout]
      current_mode = nil
      if m = output.match(/\s-\s(?:status\sis\s)?(\w*)(?:\smode|[^\n])$/m)
        current_mode = m[1]
      end

      current_path = nil
      if m = output.match(/^\s*link currently points to ([^\n]*)$/m)
        current_path = m[1].strip
      end

      current_link = nil
      if m = output.match(/^\s*link \w+ is ([^\n]*)$/m)
        current_link = m[1].strip
      end

      subcmd_path_map = {} of String => String?
      output.scan(/^\s*(?:slave|follower) (\S+) is ([^\n]*)$/m) do |sub_blk|
        subcmd_path_map[sub_blk[1]] = sub_blk[2]
      end
      if subcmd_path_map.empty? && subcommands
        subcommands.each do |sub|
          name_value = sub["name"]?.try(&.as_s?)
          subcmd_path_map[name_value] = sub["link"].as_s? if name_value
        end
      end

      output.scan(/^(\/\S*)\s-\s(?:family\s(\S+)\s)?priority\s(\d+)((?:\s+(?:slave|follower)[^\n]*)*)/m) do |am_blk|
        # Real stores Python's findall group verbatim: on Debian the
        # optional family group never participates, findall yields "" -
        # NOT None. That distinction is load-bearing: is_same_family
        # compares it against the task's `family:` param (None when the
        # task gives none), and `"" == None` is False, so a Debian
        # `alternatives: {name: editor, path: /usr/bin/vim.basic}` whose
        # current link points elsewhere DOES run `--set` (changed).
        # Storing nil made nil == nil true and silently skipped the
        # select - reported ok where Ansible reported changed (found via
        # do1jlr.base's own "vim is our editor" task and
        # chusiang.vim-and-vi-mode's "switch default editor to vim",
        # rounds 1500247/1500533).
        parsed_subcommands = [] of Subcommand
        am_blk[4].scan(/^\s+(?:slave|follower) ([^\n]*): ([^\n]*)$/m) do |sub_blk|
          next if sub_blk[2] == "(null)"
          parsed_subcommands << {name: sub_blk[1], path: sub_blk[2], link: subcmd_path_map[sub_blk[1]]?}
        end
        current_alternatives[am_blk[1]] = {priority: am_blk[3].to_i, family: am_blk[2]? || "", subcommands: parsed_subcommands}
      end

      populate_before_diff(path, current_mode, current_path, current_link, current_alternatives)
      {current_mode, current_path, current_link, current_alternatives}
    end

    # Real's parse() ends with the before side: the requested path's
    # current priority/link (plus its subcommands, and state=selected when
    # manual mode has another path selected), or state=absent when the path
    # is not registered - `None in dict` is False in Python, so a
    # family-only task records state=absent too.
    private def populate_before_diff(path : String?, current_mode : String?, current_path : String?, current_link : String?, current_alternatives : Hash(String, Alternative)) : Nil
      return unless diff_mode? && current_mode
      if path && (current = current_alternatives[path]?)
        @diff_before["state"] = JSON::Any.new("present")
        @diff_before["path"] = JSON::Any.new(path)
        @diff_before["priority"] = JSON::Any.new(current[:priority])
        @diff_before["link"] = json_or_null(current_link)
        unless current[:subcommands].empty?
          @diff_before["subcommands"] = JSON::Any.new(current[:subcommands].map { |sub| subcommand_json(sub) })
        end
        if current_mode == "manual" && current_path != path
          @diff_before["state"] = JSON::Any.new("selected")
        end
      else
        @diff_before["state"] = JSON::Any.new("absent")
      end
    end

    private def shell_quote(s : String) : String
      "'" + s.gsub("'", "'\\''") + "'"
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::AlternativesPlugin.new(config)
plugin.run
