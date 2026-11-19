#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # community.general.elasticsearch_plugin - Elasticsearch plugin
  # management through the distribution's own `elasticsearch-plugin` (or
  # legacy `plugin`) binary.
  #
  # Implemented for tenantcloud.elk_backup (issue #1588): real Ansible
  # EXECUTES this module in --check too, and its get_plugin_bin() probe
  # fails before any state work on a host without Elasticsearch ("None
  # does not exist and no other valid plugin installers were found. Make
  # sure Elasticsearch is installed."). krikri dropped the task as an
  # unimplemented plugin, printed `skipping:`, and let the play run on to
  # a later task whose fatal looked nothing like real's.
  #
  # The binary probe also happens before the state/plugin-presence
  # check, so a host with no Elasticsearch never reports the idempotent
  # "already installed" answer real would only reach with a usable
  # installer.
  class ElasticsearchPluginPlugin < BasePlugin
    # Real PLUGIN_BIN_PATHS, in the module's declaration order.
    PLUGIN_BIN_PATHS = %w[
      /usr/share/elasticsearch/bin/elasticsearch-plugin
      /usr/share/elasticsearch/bin/plugin
    ]
    DEFAULT_PLUGIN_DIR = "/usr/share/elasticsearch/plugins/"
    # The registered result order real produces: the module's own
    # exit_json kwargs, then the controller's stdout_lines/stderr_lines
    # split (ansible-core's _task.py appends them after result_data).
    RESULT_KEY_ORDER = [
      "changed", "cmd", "name", "state", "url", "timeout",
      "stdout", "stderr", "stdout_lines", "stderr_lines",
    ]

    def execute : PluginResult
      if failure = validate_params
        return failure
      end

      name = @params["name"]? || ""
      state = @params["state"]? || "present"
      plugin_dir, plugin_bin_param, plugin_bin = installer_paths
      # Real runs the probe before looking at the plugin directory or
      # the requested state, so a missing installer is always the fatal.
      return missing_installer(plugin_bin_param) unless plugin_bin

      # Real exit_json(changed=False, name=name, state=state).
      if settled?(plugin_dir, name, state)
        return PluginResult.new(changed: false, failed: false, name: name, state: state)
      end

      check_mode = true?(@params["_ansible_check_mode"]?)
      if state == "present"
        install_plugin(plugin_bin, name, check_mode)
      else
        remove_plugin(plugin_bin, name, check_mode)
      end
    end

    private def validate_params : PluginResult?
      unless @params["name"]?
        return missing_required("name")
      end

      state = @params["state"]? || "present"
      unless state == "present" || state == "absent"
        # Real argument_spec: choices=list(PACKAGE_STATE_MAP.keys()),
        # and PACKAGE_STATE_MAP is declared present-then-absent, so the
        # error lists them in that order.
        return PluginResult.new(changed: false, failed: true,
          msg: "value of state must be one of: present, absent, got: #{state}")
      end

      if @params["src"]? && @params["url"]?
        return PluginResult.new(changed: false, failed: true,
          msg: "parameters are mutually exclusive: src|url")
      end

      nil
    end

    private def missing_required(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "missing required arguments: #{name}")
    end

    # Both are type="path" in real's argument_spec, so they are
    # expanduser+expandvars'd before the module body (and before the
    # failure message quotes the parameter). An empty parameter is
    # falsy in Python, so it takes the default search rather than being
    # searched for by its (empty) name.
    private def installer_paths : {String, String?, String?}
      plugin_dir = expand_tilde(expand_dollar_vars(@params["plugin_dir"]? || DEFAULT_PLUGIN_DIR))
      plugin_bin_param = @params["plugin_bin"]?.try { |raw| expand_tilde(expand_dollar_vars(raw)) }
      {plugin_dir, plugin_bin_param, valid_plugin_bin(plugin_bin_param.presence)}
    end

    private def missing_installer(plugin_bin_param : String?) : PluginResult
      # The message interpolates the RAW parameter (Python's None when
      # unset), not the resolved binary.
      PluginResult.new(changed: false, failed: true,
        msg: "#{plugin_bin_param.nil? ? "None" : plugin_bin_param} does not exist and no other valid plugin installers were found. Make sure Elasticsearch is installed.")
    end

    private def settled?(plugin_dir : String, name : String, state : String) : Bool
      present = Dir.exists?(File.join(plugin_dir, parse_plugin_repo(name)))
      (present && state == "present") || (state == "absent" && !present)
    end

    # Real get_plugin_bin(): an existing plugin_bin parameter wins;
    # otherwise the module searches by basename through get_bin_path(),
    # whose opt_dirs (the default install dir plus the parameter's own
    # dirname) are checked before PATH.
    private def valid_plugin_bin(plugin_bin : String?) : String?
      if plugin_bin && File.file?(plugin_bin)
        return plugin_bin
      end

      bin_paths = PLUGIN_BIN_PATHS.dup
      if plugin_bin && !bin_paths.includes?(plugin_bin)
        bin_paths.unshift(plugin_bin)
      end
      dirs = [] of String
      bin_paths.each { |path| dirs << File.dirname(path) unless dirs.includes?(File.dirname(path)) }
      bins = [] of String
      bin_paths.each { |path| bins << File.basename(path) unless bins.includes?(File.basename(path)) }

      # Real iterates sets here, so WHICH of several present installers
      # wins is arbitrary in ansible; only the failure is deterministic.
      bins.each do |bin_file|
        if found = find_bin_path(bin_file, dirs)
          return found
        end
      end
      nil
    end

    # AnsibleModule.get_bin_path(arg, opt_dirs): existing opt_dirs first,
    # then PATH, then the sbin dirs that exist and are not already listed.
    private def find_bin_path(arg : String, opt_dirs : Array(String)) : String?
      paths = [] of String
      opt_dirs.each { |dir| paths << dir if Dir.exists?(dir) }
      paths.concat((ENV["PATH"]? || "").split(':'))
      {"/sbin", "/usr/sbin", "/usr/local/sbin"}.each do |dir|
        paths << dir if !paths.includes?(dir) && Dir.exists?(dir)
      end

      paths.each do |dir|
        next if dir.empty?
        candidate = File.join(dir, arg)
        return candidate if File.exists?(candidate) && !File.directory?(candidate) && File::Info.executable?(candidate)
      end
      nil
    end

    # Real parse_plugin_repo(): username/pluginname takes the second
    # segment, then one leading elasticsearch-/es- is stripped.
    private def parse_plugin_repo(name : String) : String
      elements = name.split('/')
      repo = elements.size > 1 ? elements[1] : elements[0]
      {"elasticsearch-", "es-"}.each do |prefix|
        return repo[prefix.size..] if repo.starts_with?(prefix)
      end
      repo
    end

    private def install_plugin(plugin_bin : String, name : String, check_mode : Bool) : PluginResult
      src = @params["src"]?
      url = @params["url"]?
      timeout = @params["timeout"]? || "1m"
      force = true?(@params["force"]?)

      cmd = [plugin_bin, "install"]
      plugin_name = name

      # --timeout and version are only valid for the legacy `plugin`
      # binary (Elasticsearch 1.x/2.x), and real assigns the versioned
      # name to index 2 - which lands ON TOP of the "--timeout" it just
      # appended, leaving the orphaned timeout value beside it. That
      # quirk is the argv real hands the installer, so it is reproduced.
      if File.basename(plugin_bin) == "plugin"
        unless timeout.empty?
          cmd << "--timeout"
          cmd << timeout
        end
        if version = @params["version"]?
          plugin_name = "#{plugin_name}/#{version}"
          # Python's cmd[2] = ... appends when the list is still just
          # [bin, "install"] (an empty timeout skipped the pair).
          if cmd.size > 2
            cmd[2] = plugin_name
          else
            cmd << plugin_name
          end
        end
      end

      if url
        cmd << "--url"
        cmd << url
      end
      cmd << "--batch" if force
      cmd << (src || plugin_name)

      rc, output, error_text = run_command(cmd, check_mode)
      if rc != 0
        return PluginResult.new(changed: false, failed: true,
          msg: "Installing plugin '#{name}' failed: #{parse_error(output)}", err: error_text)
      end

      PluginResult.new(changed: true, failed: false,
        cmd: cmd, name: name, state: "present", url: url, timeout: timeout,
        stdout: output, stderr: error_text,
        stdout_lines: output.lines(chomp: true), stderr_lines: error_text.lines(chomp: true),
        key_order: RESULT_KEY_ORDER)
    end

    private def remove_plugin(plugin_bin : String, name : String, check_mode : Bool) : PluginResult
      cmd = [plugin_bin, "remove", parse_plugin_repo(name)]

      rc, output, error_text = run_command(cmd, check_mode)
      if rc != 0
        return PluginResult.new(changed: false, failed: true,
          msg: "Removing plugin '#{name}' failed: #{parse_error(output)}", err: error_text)
      end

      PluginResult.new(changed: true, failed: false,
        cmd: cmd, name: name, state: "absent", url: @params["url"]?,
        timeout: @params["timeout"]? || "1m", stdout: output, stderr: error_text,
        stdout_lines: output.lines(chomp: true), stderr_lines: error_text.lines(chomp: true),
        key_order: RESULT_KEY_ORDER)
    end

    # Real skips run_command entirely under check mode and reports the
    # literal "check mode" as the command's stdout.
    private def run_command(cmd : Array(String), check_mode : Bool) : {Int32, String, String}
      return {0, "check mode", ""} if check_mode

      command = cmd.map { |arg| Shell.quote_arg(arg) }.join(" ")
      if (proxy_host = @params["proxy_host"]?) && (proxy_port = @params["proxy_port"]?)
        # Real sets run_command_environ_update for the plugin installer
        # (both the ES 8.x and older variable names).
        options = [
          "-Dhttp.proxyHost=#{proxy_host}",
          "-Dhttp.proxyPort=#{proxy_port}",
          "-Dhttps.proxyHost=#{proxy_host}",
          "-Dhttps.proxyPort=#{proxy_port}",
        ].map { |option| Shell.single_quote(option) }.join(" ")
        command = "export CLI_JAVA_OPTS=#{options} ES_JAVA_OPTS=#{options}; #{command}"
      end

      result = remote_exec(command, force_shell: true)
      {result[:exit_code], result[:stdout], result[:stderr]}
    end

    # Real parse_error(): an installer failure's message is the text
    # after the first "ERROR: ", otherwise the whole stdout.
    private def parse_error(output : String) : String
      marker = "ERROR: "
      if index = output.index(marker)
        output[(index + marker.size)..].strip
      else
        output
      end
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::ElasticsearchPluginPlugin.new(config)
plugin.run
