require "json"
require "./bigint_json"

module Krikri
  # Native community.general.onepassword lookup - the same class as the
  # natively implemented amazon.aws.aws_secret (issue #689): the
  # collection is deliberately supported, the lookup runs on the
  # CONTROLLER (it wraps the `op` 1Password CLI), and PythonLookupRunner
  # deliberately does not see installed collections' plugins - so the
  # dispatch chain fell through to the "undefined" sentinel and the task
  # silently succeeded with the literal text "undefined", never failing
  # even when the item did not exist (issue #1059).
  #
  # Semantics mirror community.general's own lookup plugin (GPL, read for
  # parity): get_bin_path locates `op`, `op --version` picks the CLI
  # v1/v2 command shape, a session is asserted (signing in when none
  # exists), then `op item get` runs per term and the requested field is
  # extracted. Errors raise Error with the plugin's own message text (no
  # wrapper prefix) - the dispatchers add the generic "The lookup plugin
  # '<name as spelled>' failed: " shape around it.
  #
  # One wart is reproduced deliberately: the plugin raises
  # `AnsibleLookupError(str(err))` where err is the captured stderr BYTES,
  # so a failed `op` run surfaces Python's bytes repr of that stderr
  # (`b'[ERROR] ...\n'`, quotes and escapes as Python prints them) as the
  # task failure message. The "isn't an item in the vault" failure from
  # the issue is exactly this path, and only reproducing the repr
  # byte-for-byte keeps the failure identical to ansible's.
  module OnePasswordLookup
    class Error < Exception
    end

    # The lookup's resolved options. Ansible resolves these through the
    # plugin config manager (documented defaults, the vault_password
    # alias, the OP_* environment fallbacks) and the plugin code then
    # treats None and "" differently per check (`if vault is not None`
    # passes an empty --vault=, `if self.account_id:` ignores it), so an
    # explicitly empty option stays distinct from an absent one.
    record Opts,
      field : String,
      section : String?,
      vault : String?,
      subdomain : String?,
      domain : String,
      username : String?,
      secret_key : String?,
      master_password : String?,
      service_account_token : String?,
      account_id : String?,
      connect_host : String?,
      connect_token : String?

    # Runs the lookup over *terms* (item names/UUIDs), returning the
    # plugin's result list - one field value per term.
    def self.run(terms : Array(String), options : Hash(String, String)) : Array(JSON::Any)
      opts = resolve(options)
      bin = locate_op
      unless bin
        raise Error.new("Unable to locate 'op' command line tool: " \
                        "Failed to find required executable \"op\" in paths: #{searched_paths.join(':')}")
      end
      version = current_version(bin)
      major = version.split(".")[0]? || ""
      unless major.in?("1", "2")
        raise Error.new("op version #{version} is unsupported")
      end
      if (truthy?(opts.connect_host) || truthy?(opts.connect_token)) &&
         (opts.connect_host.nil? || opts.connect_token.nil?)
        raise Error.new("connect_host and connect_token are required together")
      end
      client = Client.new(bin, major == "2", opts)
      client.assert_logged_in
      terms.map { |term| client.get_field(term) }
    end

    # Python's repr() of a bytes object - the exact text
    # `AnsibleLookupError(str(err))` puts in the task failure when an
    # `op` run exits non-zero. Single quotes unless the payload holds a
    # single quote and no double quote (then double quotes); the chosen
    # quote and backslash are escaped, \n/\r/\t keep their short forms and
    # everything outside printable ASCII becomes \xNN (live-verified vs
    # ansible-core 2.21 + community.general: the missing-item failure
    # renders `b'[ERROR] ... "name" isn\'t an item in the "vault" ...\n'`).
    def self.bytes_repr(payload : String) : String
      repr_body(payload.to_slice, escape_high: true, bytes_prefix: true)
    end

    # Python's repr() of a str - only used for the argv list inside
    # str(subprocess.CalledProcessError); same quote rule as bytes_repr
    # but non-ASCII text passes through (str repr escapes code points,
    # not bytes).
    def self.str_repr(payload : String) : String
      repr_body(payload.to_slice, escape_high: false, bytes_prefix: false)
    end

    private def self.repr_body(bytes : Bytes, escape_high : Bool, bytes_prefix : Bool) : String
      quote = (bytes.includes?(0x27_u8) && !bytes.includes?(0x22_u8)) ? '"' : '\''
      String.build do |io|
        io << 'b' if bytes_prefix
        io << quote
        bytes.each do |byte|
          append_repr_byte(io, byte, quote, escape_high)
        end
        io << quote
      end
    end

    private def self.append_repr_byte(io : IO, byte : UInt8, quote : Char, escape_high : Bool) : Nil
      if byte == quote.ord.to_u8 || byte == 0x5C_u8
        io << '\\' << byte.chr
      elsif short = short_escape(byte)
        io << short
      elsif byte < 0x20 || byte == 0x7F || (escape_high && byte >= 0x80)
        io << "\\x" << byte.to_s(16).rjust(2, '0')
      else
        io.write_byte(byte)
      end
    end

    private def self.short_escape(byte : UInt8) : String?
      case byte
      when 0x09 then "\\t"
      when 0x0A then "\\n"
      when 0x0D then "\\r"
      end
    end

    # get_bin_path's resolution order and its failure listing share this
    # one list: PATH first (empty entries kept - the message prints them),
    # then the /sbin dirs Ansible appends when they exist on disk.
    private def self.searched_paths : Array(String)
      paths = (ENV["PATH"]? || "").split(':')
      {"/sbin", "/usr/sbin", "/usr/local/sbin"}.each do |dir|
        paths << dir if !paths.includes?(dir) && Dir.exists?(dir)
      end
      paths
    end

    private def self.locate_op : String?
      searched_paths.each do |dir|
        next if dir.empty?
        path = File.join(dir, "op")
        return path if File.file?(path) && executable_bit?(path)
      end
      nil
    end

    # ansible's is_executable checks only that ANY execute bit is set on
    # the file's mode - not that the calling user can run it.
    private def self.executable_bit?(path : String) : Bool
      permissions = File.info(path).permissions
      permissions.owner_execute? || permissions.group_execute? || permissions.other_execute?
    rescue
      false
    end

    # The plugin's OnePassCLIBase.get_current_version: `op --version` via
    # check_output, whose CalledProcessError text is interpolated VERBATIM
    # into the failure message.
    private def self.current_version(bin : String) : String
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run(bin, ["--version"], output: stdout, error: stderr)
      unless status.success?
        argv = "[#{str_repr(bin)}, #{str_repr("--version")}]"
        raise Error.new("Unable to get the op version: Command '#{argv}' " \
                        "returned non-zero exit status #{status.exit_code}.")
      end
      stdout.to_s.strip
    end

    private def self.resolve(options : Hash(String, String)) : Opts
      Opts.new(
        field: option(options, "field") || "password",
        section: option(options, "section"),
        vault: option(options, "vault"),
        subdomain: option(options, "subdomain"),
        domain: option(options, "domain") || "1password.com",
        username: option(options, "username"),
        secret_key: option(options, "secret_key"),
        master_password: option(options, "master_password", "vault_password"),
        service_account_token: option(options, "service_account_token", env: "OP_SERVICE_ACCOUNT_TOKEN"),
        account_id: option(options, "account_id"),
        connect_host: option(options, "connect_host", env: "OP_CONNECT_HOST"),
        connect_token: option(options, "connect_token", env: "OP_CONNECT_TOKEN"),
      )
    end

    private def self.option(options : Hash(String, String), key : String,
                            alias_key : String? = nil, env : String? = nil) : String?
      return options[key] if options.has_key?(key)
      return options[alias_key] if alias_key && options.has_key?(alias_key)
      return ENV[env] if env && ENV.has_key?(env)
      nil
    end

    # Python-truthy for the option strings ("" is falsy, "0" is not).
    def self.truthy?(value : String?) : Bool
      !value.nil? && !value.empty?
    end

    # Python-truthy for a parsed JSON value - the v2 field parser's
    # `if field.get(field_name):` gate.
    def self.truthy?(value : JSON::Any) : Bool
      case raw = value.raw
      when Nil     then false
      when Bool    then raw
      when String  then !raw.empty?
      when Int64   then raw != 0
      when Float64 then raw != 0.0
      when Array   then !raw.empty?
      when Hash    then !raw.empty?
      else              true
      end
    end

    # The plugin's OnePass + OnePassCLIv1/OnePassCLIv2 trio flattened into
    # one client: the CLI versions only differ in command shape (session
    # probing, sign-in, and `op get item` vs `op item get --format json`),
    # everything else is shared.
    private class Client
      @token : String?

      def initialize(@bin : String, @v2 : Bool, @opts : Opts)
        @token = nil
      end

      def assert_logged_in : Nil
        logged_in = @v2 ? v2_logged_in? : v1_logged_in?
        set_token unless logged_in
      end

      def get_field(item_id : String) : JSON::Any
        output = get_raw(item_id)
        return JSON::Any.new("") if output.empty?
        if @v2
          parse_field_v2(output, @opts.field, @opts.section)
        else
          parse_field_v1(output, @opts.field, @opts.section)
        end
      end

      # The plugin's _run: any unexpected exit code raises with Python's
      # bytes repr of stderr (see the module comment). Every `op` failure
      # the issue cares about ("isn't an item in the vault", not signed
      # in, bad session) travels this one path.
      private def run_op(args : Array(String), expected_rc : Int32 = 0,
                         command_input : String? = nil, ignore_errors : Bool = false,
                         env_update : Hash(String, String)? = nil) : {Int32, String, String}
        stdout = IO::Memory.new
        stderr = IO::Memory.new
        status = if input = command_input
                   Process.run(@bin, args, input: IO::Memory.new(input),
                     output: stdout, error: stderr, env: env_update)
                 else
                   Process.run(@bin, args, output: stdout, error: stderr, env: env_update)
                 end
        rc = status.exit_code
        raise Error.new(OnePasswordLookup.bytes_repr(stderr.to_s)) if !ignore_errors && rc != expected_rc
        {rc, stdout.to_s, stderr.to_s}
      rescue ex : Error
        raise ex
      rescue ex : IO::Error
        # The plugin's Popen would surface the spawn error text as the
        # lookup failure - a binary vanishing between locate and run only.
        raise Error.new(ex.message.to_s)
      end

      private def v2_logged_in? : Bool
        return true if truthy?(@opts.connect_host) && truthy?(@opts.connect_token)
        if truthy?(@opts.service_account_token)
          rc, _out, _err = run_op(["whoami"],
            env_update: {"OP_SERVICE_ACCOUNT_TOKEN" => @opts.service_account_token.to_s})
          return rc == 0
        end
        args = ["account", "list"]
        args << "--account" << "#{@opts.subdomain}.#{@opts.domain}" if truthy?(@opts.subdomain)
        _rc, out_text, _err = run_op(args)
        return false if out_text.empty?
        args = ["account", "get"]
        if truthy?(@opts.account_id)
          args << "--account" << @opts.account_id.to_s
        elsif truthy?(@opts.subdomain)
          args << "--account" << "#{@opts.subdomain}.#{@opts.domain}"
        end
        rc, _out, _err = run_op(args, ignore_errors: true)
        rc == 0
      end

      private def v1_logged_in? : Bool
        args = ["get", "account"]
        if truthy?(@opts.account_id)
          args << "--account" << @opts.account_id.to_s
        elsif truthy?(@opts.subdomain)
          args << "--account" << "#{@opts.subdomain}.#{@opts.domain}"
        end
        rc, _out, _err = run_op(args, ignore_errors: true)
        rc == 0
      end

      # The plugin's set_token: an EXISTING config file means a previous
      # initial sign-in happened, so a basic `op signin` with the master
      # password suffices; its own failure falls through to the full
      # initial sign-in unless the message says the credentials themselves
      # are the problem.
      private def set_token : Nil
        config = config_file_path
        if config && File.file?(config)
          out_text = begin
            _rc, stdout, _err = signin
            stdout
          rescue ex : Error
            message = ex.message.to_s.downcase
            raise ex if message.includes?("missing required parameters") || message.includes?("unauthorized")
            _rc, stdout, _err = full_signin
            stdout
          end
          @token = out_text.strip
        else
          _rc, out_text, _err = full_signin
          @token = out_text.strip
        end
      end

      private def config_file_path : String?
        {"~/.op/config", "~/.config/op/config", "~/.config/.op/config"}.each do |path|
          expanded = File.join(Path.home, path[2..])
          return expanded if File.exists?(expanded)
        end
        nil
      end

      private def signin : {Int32, String, String}
        check_required_params(["master_password"])
        args = ["signin", "--raw"]
        if truthy?(@opts.subdomain)
          # The plugin passes the bare SUBDOMAIN here (not subdomain.domain
          # as the account-scoped commands do) - reproduced as-is.
          if @v2
            args << "--account" << @opts.subdomain.to_s
          else
            args << @opts.subdomain.to_s
          end
        end
        run_op(args, command_input: @opts.master_password)
      end

      private def full_signin : {Int32, String, String}
        unless @v2
          if truthy?(@opts.connect_host) || truthy?(@opts.connect_token)
            raise Error.new("1Password Connect is not available with 1Password CLI version 1. " \
                            "Please use version 2 or later.")
          end
          if truthy?(@opts.service_account_token)
            raise Error.new("1Password CLI version 1 does not support Service Accounts. " \
                            "Please use version 2 or later.")
          end
        end
        check_required_params(["subdomain", "username", "secret_key", "master_password"])
        if @v2
          run_op(["account", "add", "--raw", "--address", "#{@opts.subdomain}.#{@opts.domain}",
                  "--email", @opts.username.to_s, "--signin"],
            command_input: @opts.master_password,
            env_update: {"OP_SECRET_KEY" => @opts.secret_key.to_s})
        else
          run_op(["signin", "#{@opts.subdomain}.#{@opts.domain}", @opts.username.to_s,
                  @opts.secret_key.to_s, "--raw"],
            command_input: @opts.master_password)
        end
      end

      private def check_required_params(required : Array(String)) : Nil
        missing = required.reject { |param| truthy?(option_named(param)) }
        return if missing.empty?
        plural = missing.size > 1 ? "s" : ""
        raise Error.new("Unable to sign in to 1Password. Missing required parameter#{plural}: #{missing.join(", ")}.")
      end

      private def option_named(name : String) : String?
        case name
        when "subdomain"       then @opts.subdomain
        when "username"        then @opts.username
        when "secret_key"      then @opts.secret_key
        when "master_password" then @opts.master_password
        end
      end

      private def get_raw(item_id : String) : String
        if @v2
          args = ["item", "get", item_id, "--format", "json"]
          add_account_and_vault(args)
          if truthy?(@opts.connect_host) && truthy?(@opts.connect_token)
            raise Error.new("'vault' is required with 1Password Connect") if @opts.vault.nil?
            env = {"OP_CONNECT_HOST" => @opts.connect_host.to_s, "OP_CONNECT_TOKEN" => @opts.connect_token.to_s}
            _rc, out_text, _err = run_op(args, env_update: env)
            return out_text
          end
          if truthy?(@opts.service_account_token)
            raise Error.new("'vault' is required with 'service_account_token'") if @opts.vault.nil?
            env = {"OP_SERVICE_ACCOUNT_TOKEN" => @opts.service_account_token.to_s}
            _rc, out_text, _err = run_op(args, env_update: env)
            return out_text
          end
          args << "--session=#{@token}" unless @token.nil?
          _rc, out_text, _err = run_op(args)
          out_text
        else
          args = ["get", "item", item_id]
          args << "--account" << @opts.account_id.to_s if truthy?(@opts.account_id)
          args << "--vault=#{@opts.vault}" unless @opts.vault.nil?
          args << "--session=#{@token}" unless @token.nil?
          _rc, out_text, _err = run_op(args)
          out_text
        end
      end

      private def add_account_and_vault(args : Array(String)) : Nil
        args << "--account" << @opts.account_id.to_s if truthy?(@opts.account_id)
        args << "--vault=#{@opts.vault}" unless @opts.vault.nil?
      end

      # The v2 item JSON's field extraction: an exact key hit on the field
      # DICT first (a `field=` naming one of the field's own keys), then
      # label, then id - optionally scoped to a section's label/id.
      private def parse_field_v2(data_json : String, field_name : String, section_title : String?) : JSON::Any
        data = BigJson.parse(data_json)
        wanted = field_name.downcase
        fields = data["fields"]?.try(&.as_a?) || [] of JSON::Any
        fields.each do |field|
          if section_title.nil?
            if (direct = field[wanted]?) && OnePasswordLookup.truthy?(direct)
              return direct
            end
            if matched = field_value_for(field, wanted)
              return matched
            end
          else
            section = field["section"]?.try(&.as_h?) || {} of String => JSON::Any
            current = (section["label"]? || section["id"]? || JSON::Any.new("")).as_s? || ""
            if section_title.downcase == current.downcase
              if matched = field_value_for(field, wanted)
                return matched
              end
            end
          end
        end
        JSON::Any.new("")
      end

      # Returns the field's `value` when the field's label or id matches
      # *wanted* (label first), nil when neither does. A matched-but-absent
      # value reads as "" (Python's .get("value", "")); a JSON null value
      # stays null (Python returns None).
      private def field_value_for(field : JSON::Any, wanted : String) : JSON::Any?
        label = (field["label"]?.try(&.as_s?) || "").downcase
        id = (field["id"]?.try(&.as_s?) || "").downcase
        return nil unless label == wanted || id == wanted
        field["value"]? || JSON::Any.new("")
      end

      # The v1 `op get item` payload nests fields under details, and a
      # details-level key hit wins BEFORE the fields/sections walk (which
      # only runs when no section was requested).
      private def parse_field_v1(data_json : String, field_name : String, section_title : String?) : JSON::Any
        data = BigJson.parse(data_json)
        details = data["details"]?.try(&.as_h?) || {} of String => JSON::Any
        if section_title.nil?
          if direct = details[field_name]?
            return direct
          end
          if matched = v1_plain_field(details, field_name)
            return matched
          end
        end
        v1_section_field(details, field_name, section_title) || JSON::Any.new("")
      end

      private def v1_plain_field(details : Hash(String, JSON::Any), field_name : String) : JSON::Any?
        fields = details["fields"]?.try(&.as_a?) || [] of JSON::Any
        fields.each do |field|
          if (field["name"]?.try(&.as_s?) || "").downcase == field_name.downcase
            return field["value"]? || JSON::Any.new("")
          end
        end
        nil
      end

      private def v1_section_field(details : Hash(String, JSON::Any), field_name : String,
                                   section_title : String?) : JSON::Any?
        sections = details["sections"]?.try(&.as_a?) || [] of JSON::Any
        sections.each do |section_data|
          title = section_data["title"]?.try(&.as_s?) || ""
          next if !section_title.nil? && section_title.downcase != title.downcase
          section_data["fields"]?.try(&.as_a?).try &.each do |field|
            if (field["t"]?.try(&.as_s?) || "").downcase == field_name.downcase
              return field["v"]? || JSON::Any.new("")
            end
          end
        end
        nil
      end

      private def truthy?(value : String?) : Bool
        OnePasswordLookup.truthy?(value)
      end
    end
  end
end
