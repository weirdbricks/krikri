#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"

module Krikri
  # sudoers plugin - manages /etc/sudoers.d/-style rule files.
  # Compatible with (a subset of) Ansible's community.general.sudoers
  # module.
  #
  # Parameters:
  #   name (required): rule filename under sudoers_path
  #   state: present (default) / absent
  #   user / group: mutually exclusive; owner of the rule
  #   commands: required when state: present - list (or comma-separated
  #     string) of allowed commands, or "ALL"
  #   defaults: list of Defaults directives written before the rule,
  #     scoped to the user/group owner (real's 13.1.0 `defaults` param)
  #   noexec / nopassword (default true) / setenv: bools
  #   host: default "ALL"
  #   runas: optional target user
  #   sudoers_path: default "/etc/sudoers.d"
  #   validation: detect (default) / required / absent - whether to run
  #     `visudo -c -f -` against the generated content before writing
  class SudoersPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    FILE_MODE = 0o440

    # Real argument_spec (community.general sudoers.py) - no aliases.
    SPEC = {
      "commands"     => %w[],
      "defaults"     => %w[],
      "group"        => %w[],
      "host"         => %w[],
      "name"         => %w[],
      "noexec"       => %w[],
      "nopassword"   => %w[],
      "runas"        => %w[],
      "setenv"       => %w[],
      "state"        => %w[],
      "sudoers_path" => %w[],
      "user"         => %w[],
      "validation"   => %w[],
    }

    def execute : PluginResult
      if err = validate_arguments
        return err
      end

      name = @params["name"].not_nil!
      state = @params["state"]? || "present"
      sudoers_path = @params["sudoers_path"]? || "/etc/sudoers.d"
      file = File.join(sudoers_path, name)
      check_mode = true?(@params["_ansible_check_mode"]?)

      return remove_rule(file, name, check_mode) if state == "absent"

      write_rule(file, name, sudoers_path, check_mode)
    end

    # Real AnsibleModule setup surface, in the validator's errors[0]
    # order (arg_spec.py: mutually exclusive -> required -> types ->
    # choices -> required_if -> unsupported).
    private def validate_arguments : PluginResult?
      if @params["user"]? && @params["group"]?
        return PluginResult.new(changed: false, failed: true,
          msg: "parameters are mutually exclusive: user|group")
      end

      unless @params["name"]?
        return missing_required_error(["name"])
      end

      {"noexec", "nopassword", "setenv"}.each do |param|
        next unless raw = @params[param]?
        next if bool_convertible?(raw)
        return bool_type_error(param, raw)
      end

      state = @params["state"]? || "present"
      unless %w[present absent].includes?(state)
        return choices_error("state", %w[present absent], state)
      end

      validation = @params["validation"]? || "detect"
      unless %w[absent detect required].includes?(validation)
        return choices_error("validation", %w[absent detect required], validation)
      end

      # required_if=[("state", "present", ["commands"])]: only a MISSING
      # key fails. An empty list passes real's required_if (the key is
      # present) and dies at visudo/write instead - S20 vs S21 in the
      # podman-diff case file.
      if state == "present" && !@params["commands"]?
        return PluginResult.new(changed: false, failed: true,
          msg: "state is present but all of the following are missing: commands")
      end

      if unsupported = unsupported_param_keys(@params, SPEC)
        unless unsupported.empty?
          return unsupported_params_error("community.general.sudoers", unsupported, SPEC)
        end
      end

      nil
    end

    private def remove_rule(file : String, name : String, check_mode : Bool) : PluginResult
      return PluginResult.new(changed: false, failed: false, msg: "Sudoers rule #{name} already absent") unless File.exists?(file)

      File.delete(file) unless check_mode
      PluginResult.new(changed: true, failed: false, msg: "Removed sudoers rule #{name}")
    end

    private def write_rule(file : String, name : String, sudoers_path : String, check_mode : Bool) : PluginResult
      content, content_error = build_validated_content
      return content_error if content_error

      if File.exists?(file) && File.read(file) == content && (File.info(file).permissions.value & 0o777) == FILE_MODE
        return PluginResult.new(changed: false, failed: false, msg: "Sudoers rule #{name} already up to date")
      end

      return PluginResult.new(changed: true, failed: false, msg: "Would write sudoers rule #{name} (check mode)") if check_mode

      # Real write() opens the file directly - a missing sudoers_path is
      # a failed write (FileNotFoundError), NOT an auto-created
      # directory.
      unless Dir.exists?(sudoers_path)
        return PluginResult.new(changed: false, failed: true,
          msg: "[Errno 2] No such file or directory: '#{file}'")
      end

      File.write(file, content.as(String))
      File.chmod(file, FILE_MODE)

      PluginResult.new(changed: true, failed: false, msg: "Wrote sudoers rule #{name}")
    end

    private def build_validated_content : {String?, PluginResult?}
      user = @params["user"]?
      group = @params["group"]?
      if !user && !group
        return {nil, PluginResult.new(changed: false, failed: true, msg: "one of the following is required: user, group")}
      end

      content = build_content(user, group, parse_list_param("commands"))
      validation = @params["validation"]? || "detect"

      if validation != "absent"
        validate_result = validate(content, validation)
        return {nil, validate_result} if validate_result
      end

      {content, nil}
    end

    private def build_content(user : String?, group : String?, commands : Array(String)) : String
      owner = user || "%#{group}"
      host = @params["host"]? || "ALL"
      noexec_str = true?(@params["noexec"]?) ? "NOEXEC:" : ""
      nopassword_str = true?(@params["nopassword"]?, default: true) ? "NOPASSWD:" : ""
      setenv_str = true?(@params["setenv"]?) ? "SETENV:" : ""
      runas = @params["runas"]?
      runas_str = runas ? "(#{runas})" : ""
      commands_str = commands.join(", ")

      defaults_str = parse_list_param("defaults").map { |default| "Defaults:#{owner} #{default}" }
                      .join("\n")
      defaults_str += "\n" unless defaults_str.empty?

      "#{defaults_str}#{owner} #{host}=#{runas_str}#{noexec_str}#{nopassword_str}#{setenv_str} #{commands_str}\n"
    end

    # A real list-typed param's wire shape: a whole-value `{{ list_var }}`
    # arrives as the double-quoted JSON the wire serialized it to (see
    # apt.cr's parse_package_names); everything else is a plain string,
    # which real check_type_list comma-splits WITHOUT stripping the
    # elements ("cmd1, cmd2" -> ["cmd1", " cmd2"], podman-diff S8).
    private def parse_list_param(key : String) : Array(String)
      raw = @params[key]?
      return [] of String unless raw

      value = (JSON.parse(raw) rescue nil)
      value = value.nil? ? raw : value.raw

      case value
      when Array
        value.map { |entry| entry.as_s? ? entry.as_s : entry.to_s }
      when String
        value.split(",")
      else
        [value.to_s]
      end
    end

    private def validate(content : String, validation : String) : PluginResult?
      visudo = find_visudo
      unless visudo
        return PluginResult.new(changed: false, failed: true, msg: "visudo is required but not found") if validation == "required"
        return nil
      end

      process = Process.new(visudo, ["-c", "-f", "-"], input: Process::Redirect::Pipe, output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
      process.input.print(content)
      process.input.close
      out = process.output.gets_to_end
      err = process.error.gets_to_end
      status = process.wait

      return nil if status.success?

      PluginResult.new(changed: false, failed: true, msg: "Failed to validate sudoers rule:\n#{out.empty? ? err : out}")
    end

    private def find_visudo : String?
      ["/usr/sbin/visudo", "/sbin/visudo"].find { |path| File.exists?(path) } || Process.find_executable("visudo")
    end

  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::SudoersPlugin.new(config)
plugin.run
