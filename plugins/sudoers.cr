#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
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
  #   noexec / nopassword (default true) / setenv: bools
  #   host: default "ALL"
  #   runas: optional target user
  #   sudoers_path: default "/etc/sudoers.d"
  #   validation: detect (default) / required / absent - whether to run
  #     `visudo -c -f -` against the generated content before writing
  class SudoersPlugin < BasePlugin
    FILE_MODE = 0o440

    def execute : PluginResult
      name = @params["name"]?
      return missing_param("name") unless name

      state = @params["state"]? || "present"
      sudoers_path = @params["sudoers_path"]? || "/etc/sudoers.d"
      file = File.join(sudoers_path, name)
      check_mode = true?(@params["check_mode"]?)

      return remove_rule(file, name, check_mode) if state == "absent"

      write_rule(file, name, sudoers_path, check_mode)
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

      Dir.mkdir_p(sudoers_path) unless Dir.exists?(sudoers_path)
      File.write(file, content.as(String))
      File.chmod(file, FILE_MODE)

      PluginResult.new(changed: true, failed: false, msg: "Wrote sudoers rule #{name}")
    end

    private def build_validated_content : {String?, PluginResult?}
      commands = parse_commands
      if commands.empty?
        return {nil, PluginResult.new(changed: false, failed: true, msg: "state is present but 'commands' is missing")}
      end

      user = @params["user"]?
      group = @params["group"]?
      if !user && !group
        return {nil, PluginResult.new(changed: false, failed: true, msg: "one of the following is required: user, group")}
      end

      content = build_content(user, group, commands)
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

      "#{owner} #{host}=#{runas_str}#{noexec_str}#{nopassword_str}#{setenv_str} #{commands_str}\n"
    end

    # commands: is a real Ansible list-typed param - see this repo's
    # dnf.cr's own "list" param handling for the exact same JSON-vs-
    # Python-repr-string parsing this mirrors.
    private def parse_commands : Array(String)
      raw = @params["commands"]?
      return [] of String unless raw

      begin
        parsed = JSON.parse(raw)
        return parsed.as_a.map(&.as_s) if parsed.as_a?
        return [parsed.as_s] if parsed.as_s?
      rescue
      end

      begin
        return Array(String).from_json(raw.gsub('\'', '"'))
      rescue
      end

      raw.includes?(",") ? raw.split(",").map(&.strip) : [raw]
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

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: #{name}")
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::SudoersPlugin.new(config)
plugin.run
