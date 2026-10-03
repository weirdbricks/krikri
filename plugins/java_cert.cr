#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/get_bin_path"
require "../src/krikri/plugin_helpers/java_cert_command"
require "../src/krikri/plugin_helpers/run_command_failure"

module Krikri
  # java_cert plugin - a native port of community.general.java_cert
  # (read from a live collection install), the keytool wrapper that
  # imports/removes certificates from a Java keystore.
  #
  # Follows the real module's control flow:
  #   - exactly one of cert_url/cert_path/cert_content/pkcs12_path per
  #     the required_if/mutually_exclusive spec (absent needs one of
  #     cert_url/cert_alias); cert_alias defaults to cert_url
  #   - keytool must be runnable, and the keystore must already exist
  #     unless keystore_create is set
  #   - alias presence via keytool -list ... -rfc (password on stdin);
  #   - state=present compares the sha256 digest of the certificate
  #     already under the alias (extracted through openssl x509, with
  #     the real module's DER fallback) against the requested
  #     certificate (from path, content, PKCS12 export, or
  #     keytool -printcert over TLS), and re-imports (delete first)
  #     only on digest change - the real module's "always insert, even
  #     if the alias exists" is really "insert when the digest
  #     differs"
  #   - state=absent deletes the alias when present
  #   - check mode exits changed=true without running the mutation
  #
  # Deliberately left out (noted, not silently dropped): the
  # file-common-args permission management (mode/owner/group/se*)
  # which the real module applies to the keystore file - keystore
  # attributes stay untouched here.
  class JavaCertPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # The real module's argument_spec plus the file-common args its
    # add_file_common_args=True injects - the only alias is
    # attributes->attr (ansible-core's FILE_COMMON_ARGUMENTS).
    SPEC = {
      "cert_url"        => [] of String,
      "cert_path"       => [] of String,
      "cert_content"    => [] of String,
      "pkcs12_path"     => [] of String,
      "pkcs12_password" => [] of String,
      "pkcs12_alias"    => [] of String,
      "cert_alias"      => [] of String,
      "cert_port"       => [] of String,
      "keystore_path"   => [] of String,
      "keystore_pass"   => [] of String,
      "trust_cacert"    => [] of String,
      "keystore_create" => [] of String,
      "keystore_type"   => [] of String,
      "executable"      => [] of String,
      "state"           => [] of String,
      "attributes"      => ["attr"],
      "group"           => [] of String,
      "mode"            => [] of String,
      "owner"           => [] of String,
      "selevel"         => [] of String,
      "serole"          => [] of String,
      "setype"          => [] of String,
      "seuser"          => [] of String,
      "unsafe_writes"   => [] of String,
    }

    def execute : PluginResult
      if err = validate_arguments
        return err
      end
      url = @params["cert_url"]?
      path = @params["cert_path"]?
      content = @params["cert_content"]?
      port = @params["cert_port"]?.try(&.to_i) || 443

      pkcs12_path = @params["pkcs12_path"]?
      pkcs12_pass = @params["pkcs12_password"]? || ""
      # The real module's `module.params.get("pkcs12_alias", "1")` is
      # dead code - module.params always contains the key (None unless
      # set), so pkcs12_alias is None unless explicitly passed. The
      # distinction is load-bearing: newer keytool rejects -destalias
      # without -srcalias, so the real module's pkcs12 import FAILS
      # whenever cert_alias is set and pkcs12_alias is not.
      pkcs12_alias = @params["pkcs12_alias"]?

      cert_alias = @params["cert_alias"]? || url
      trust_cacert = true?(@params["trust_cacert"]?)
      keystore_path = @params["keystore_path"]?
      keystore_pass = @params["keystore_pass"]?.not_nil!
      keystore_create = true?(@params["keystore_create"]?)
      keystore_type = @params["keystore_type"]?
      executable = @params["executable"]? || "keytool"
      state = @params["state"]? || "present"

      if path && !cert_alias
        # real: fail_json(changed=False, msg=...) - changed is a caller
        # kwarg so it LEADS, before failed/msg.
        return PluginResult.new(changed: false, failed: true,
          msg: "Using local path import from #{keystore_path || "None"} requires alias argument.",
          key_order: ["changed", "failed", "msg"])
      end

      # Real main() resolves openssl via get_bin_path('openssl', True)
      # here and then runs test_keytool. The openssl resolution is
      # DEFERRED to first use (the digest computation below): real only
      # ever USES the binary after the keytool probe, so on a host
      # without keytool the keytool failure is what surfaces - in exact
      # real order, only when openssl itself is missing does the bin
      # lookup failure come first. Deferring keeps that ordering honest
      # in both directions.
      #
      # Real test_keytool: module.run_command([executable], check_rc=True)
      # - the exec failure shape (rc=errno, "Error executing command." +
      # the [Errno] exception text), NOT a get_bin_path wording.
      if failure = PluginHelpers::RunCommandFailure.exec_check(executable)
        return PluginHelpers::RunCommandFailure.exec_failure(executable, failure[0], failure[1], executable)
      end
      keytool_check = remote_exec(executable)
      return PluginHelpers::RunCommandFailure.nonzero_exit(executable, keytool_check[:exit_code], keytool_check[:stdout], keytool_check[:stderr]) unless keytool_check[:exit_code] == 0

      if !keystore_create && !keystore_path.nil? && !remote_file_exists?(keystore_path.not_nil!)
        # real: fail_json(changed=False, msg=...) - changed is a caller
        # kwarg so it LEADS, before failed/msg.
        return PluginResult.new(changed: false, failed: true,
          msg: "Module require existing keystore at keystore_path '#{keystore_path}'",
          key_order: ["changed", "failed", "msg"])
      end

      check_mode = true?(@params["_ansible_check_mode"]?)
      keystore_pass_str = keystore_pass

      alias_exists, alias_exists_output = check_cert_present(executable, keystore_path || "", keystore_pass_str, cert_alias || "", keystore_type)

      if state == "absent"
        if alias_exists
          # real: exit_json(changed=True) - no msg at all
          return PluginResult.new(changed: true, failed: false) if check_mode
          return delete_cert(executable, keystore_path.not_nil!, keystore_pass_str, cert_alias.not_nil!, keystore_type)
        end
        # real: result stays the empty dict, exit_json(**result) backfills
        # changed: false - registered shape is just [changed, failed]
        return PluginResult.new(changed: false, failed: false)
      end

      # No cert_alias with state=present is what real runs too (its own
      # command list would carry a None alias); the keystore commands
      # built here use an empty alias in that case - unreachable in
      # parity runs anyway, since keytool itself is missing in both
      # engines' containers and test_keytool above fails first.
      cert_alias_str = cert_alias || ""

      keystore_cert_digest = ""
      if alias_exists
        openssl_bin = require_openssl
        return openssl_bin if openssl_bin.is_a?(PluginResult)
        old_tmp = File.tempname("java-cert-old")
        File.write(old_tmp, alias_exists_output)
        digest = x509_digest(openssl_bin.as(String), old_tmp)
        File.delete(old_tmp) rescue nil
        return digest if digest.is_a?(PluginResult)
        keystore_cert_digest = digest.as(String)
      end

      new_tmp = File.tempname("java-cert-new")
      cleanup = true
      openssl_bin = require_openssl
      return openssl_bin if openssl_bin.is_a?(PluginResult)
      begin
        if pkcs12_path
          export_argv = PluginHelpers::JavaCertCommand.export_pkcs12_cmd(executable, pkcs12_path, pkcs12_alias)
          export = remote_exec(PluginHelpers::JavaCertCommand.with_stdin(export_argv.join(' '), [pkcs12_pass]))
          # real: fail_json(msg=..., stderr=export_err, rc=export_rc) -
          # kwargs lead (stderr before rc), failed/msg follow, the
          # controller appends stderr_lines (stderr present, stdout not).
          return PluginResult.new(changed: false, failed: true,
            msg: "Internal module failure, cannot extract public certificate from PKCS12, message: #{export[:stdout]}",
            stderr: export[:stderr], stderr_lines: export[:stderr].lines,
            rc: export[:exit_code],
            key_order: ["stderr", "rc", "failed", "msg", "stderr_lines"]) unless export[:exit_code] == 0
          File.write(new_tmp, export[:stdout])
        elsif path
          new_tmp = path.not_nil!
          cleanup = false
        elsif content
          File.write(new_tmp, content.not_nil!)
        elsif url
          fetch_argv = PluginHelpers::JavaCertCommand.fetch_url_cmd(
            executable, url.not_nil!, port,
            PluginHelpers::JavaCertCommand.proxy_opts(ENV["https_proxy"]?, ENV["no_proxy"]?)
          )
          fetch = remote_exec(fetch_argv.join(' '))
          # real: fail_json(msg=..., rc=fetch_rc, cmd=fetch_cmd)
          return PluginResult.new(changed: false, failed: true,
            msg: "Internal module failure, cannot download certificate, error: #{fetch[:stderr]}",
            rc: fetch[:exit_code], cmd: fetch_argv,
            key_order: ["rc", "cmd", "failed", "msg"]) unless fetch[:exit_code] == 0
          File.write(new_tmp, fetch[:stdout])
        end

        new_digest = x509_digest(openssl_bin.as(String), new_tmp)
        return new_digest if new_digest.is_a?(PluginResult)

        if keystore_cert_digest != new_digest
          # real: exit_json(changed=True) - no msg at all
          return PluginResult.new(changed: true, failed: false) if check_mode

          if alias_exists
            delete_result = delete_cert(executable, keystore_path.not_nil!, keystore_pass_str, cert_alias_str, keystore_type)
            return delete_result if delete_result.failed?
          end

          if pkcs12_path
            return import_pkcs12(executable, pkcs12_path.not_nil!, pkcs12_pass, pkcs12_alias,
              keystore_path.not_nil!, keystore_pass_str, cert_alias_str, keystore_type)
          else
            return import_cert(executable, new_tmp, keystore_path.not_nil!, keystore_pass_str, cert_alias_str, keystore_type, trust_cacert)
          end
        end

        # real: result stays the empty dict - registered [changed, failed],
        # no msg, no cmd
        PluginResult.new(changed: false, failed: false)
      ensure
        File.delete(new_tmp) rescue nil if cleanup
      end
    end

    # Real AnsibleModule validation order (ArgumentSpecValidator.validate):
    # required -> types (spec declaration order) -> choices ->
    # required_together -> required_if -> mutually_exclusive -> unsupported
    # (deferred last).
    private def validate_arguments : PluginResult?
      return missing_required_error(["keystore_pass"]) unless @params["keystore_pass"]?

      {"cert_port" => :int, "trust_cacert" => :bool, "keystore_create" => :bool}.each do |param, type|
        next unless raw = @params[param]?
        if type == :int
          next if raw.to_i32?
          return int_type_error(param, raw)
        else
          next if bool_convertible?(raw)
          return bool_type_error(param, raw)
        end
      end

      state = @params["state"]? || "present"
      unless %w[absent present].includes?(state)
        return choices_error("state", %w[absent present], state)
      end

      sources = [@params["cert_url"]?, @params["cert_path"]?, @params["cert_content"]?, @params["pkcs12_path"]?].compact
      if state == "present" && sources.empty?
        return PluginResult.new(changed: false, failed: true,
          msg: "state is present but any of the following are missing: cert_path, cert_url, cert_content, pkcs12_path")
      end
      if state == "absent" && !@params["cert_url"]? && !@params["cert_alias"]?
        return PluginResult.new(changed: false, failed: true,
          msg: "state is absent but any of the following are missing: cert_url, cert_alias")
      end
      if sources.size > 1
        return PluginResult.new(changed: false, failed: true,
          msg: "parameters are mutually exclusive: cert_url|cert_path|cert_content|pkcs12_path")
      end

      unsupported = unsupported_param_keys(@params, SPEC)
      unless unsupported.empty?
        return unsupported_params_error("community.general.java_cert", unsupported, SPEC)
      end
      nil
    end

    private def check_cert_present(executable : String, keystore_path : String, keystore_pass : String,
                                   cert_alias : String, keystore_type : String?) : {Bool, String}
      return {false, ""} if keystore_path.empty?
      argv = PluginHelpers::JavaCertCommand.check_cmd(executable, keystore_path, cert_alias, keystore_type)
      command = PluginHelpers::JavaCertCommand.with_stdin(argv.join(' '), [keystore_pass])
      result = remote_exec(command)
      result[:exit_code] == 0 ? {true, result[:stdout]} : {false, ""}
    end

    # delete_cert: real runs keytool with check_rc=True, so a non-zero
    # exit surfaces through run_command's own failure shape (msg =
    # rstripped stderr, cmd/rc/stdout/stderr lead); success returns
    # dict(changed=True, msg=del_out, rc=, cmd=, stdout=, error=, diff=).
    private def delete_cert(executable : String, keystore_path : String, keystore_pass : String,
                            cert_alias : String, keystore_type : String?) : PluginResult
      argv = PluginHelpers::JavaCertCommand.delete_cmd(executable, keystore_path, cert_alias, keystore_type)
      command = PluginHelpers::JavaCertCommand.with_stdin(argv.join(' '), [keystore_pass])
      result = remote_exec(command)
      diff = JSON.parse({before: "#{cert_alias}\n", after: nil}.to_json)
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: result[:stderr].rstrip,
          include_empty_msg: true,
          cmd: argv, rc: result[:exit_code],
          stdout: result[:stdout], stdout_lines: result[:stdout].lines,
          stderr: result[:stderr], stderr_lines: result[:stderr].lines,
          key_order: ["cmd", "rc", "stdout", "stderr", "failed", "msg",
                      "stdout_lines", "stderr_lines", "changed", "exception"])
      end
      PluginResult.new(changed: true, failed: false,
        msg: result[:stdout], include_empty_msg: true,
        rc: result[:exit_code], cmd: argv,
        stdout: result[:stdout], stdout_lines: result[:stdout].lines,
        error: result[:stderr], diff: diff,
        key_order: ["changed", "msg", "rc", "cmd", "stdout", "error", "diff", "stdout_lines"])
    end

    # import_cert_path: real runs keytool with check_rc=False and fails
    # through its own fail_json(msg=import_out, rc=, cmd=, error=) -
    # no stdout/stderr keys, so the controller adds no *_lines.
    private def import_cert(executable : String, cert_path : String, keystore_path : String, keystore_pass : String,
                            cert_alias : String, keystore_type : String?, trust_cacert : Bool) : PluginResult
      argv = PluginHelpers::JavaCertCommand.import_cert_cmd(executable, cert_path, keystore_path, cert_alias, keystore_type, trust_cacert)
      command = PluginHelpers::JavaCertCommand.with_stdin(argv.join(' '), [keystore_pass, keystore_pass])
      result = remote_exec(command)
      diff = JSON.parse({before: "\n", after: "#{cert_alias}\n"}.to_json)
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: result[:stdout],
          include_empty_msg: true,
          rc: result[:exit_code], cmd: argv, error: result[:stderr],
          key_order: ["rc", "cmd", "error", "failed", "msg"])
      end
      PluginResult.new(changed: true, failed: false,
        msg: result[:stdout], include_empty_msg: true,
        rc: result[:exit_code], cmd: argv,
        stdout: result[:stdout], stdout_lines: result[:stdout].lines,
        error: result[:stderr], diff: diff,
        key_order: ["changed", "msg", "rc", "cmd", "stdout", "error", "diff", "stdout_lines"])
    end

    private def import_pkcs12(executable : String, pkcs12_path : String, pkcs12_pass : String, pkcs12_alias : String?,
                              keystore_path : String, keystore_pass : String, cert_alias : String,
                              keystore_type : String?) : PluginResult
      argv = PluginHelpers::JavaCertCommand.import_pkcs12_cmd(executable, pkcs12_path, pkcs12_alias, keystore_path, cert_alias, keystore_type)
      command = PluginHelpers::JavaCertCommand.with_stdin(argv.join(' '),
        !keystore_path.empty? && remote_file_exists?(keystore_path) ? [keystore_pass, pkcs12_pass] : [keystore_pass, keystore_pass, pkcs12_pass]
      )
      result = remote_exec(command)
      diff = JSON.parse({before: "\n", after: "#{cert_alias}\n"}.to_json)
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: result[:stdout],
          include_empty_msg: true,
          rc: result[:exit_code], cmd: argv, error: result[:stderr],
          key_order: ["rc", "cmd", "error", "failed", "msg"])
      end
      PluginResult.new(changed: true, failed: false,
        msg: result[:stdout], include_empty_msg: true,
        rc: result[:exit_code], cmd: argv,
        stdout: result[:stdout], stdout_lines: result[:stdout].lines,
        error: result[:stderr], diff: diff,
        key_order: ["changed", "msg", "rc", "cmd", "stdout", "error", "diff", "stdout_lines"])
    end

    # _get_digest_from_x509_file: extract the first certificate from
    # the chain (PEM, DER fallback), then sha256 it. Returns the hex
    # digest, or a failure result. Both failure shapes are the real
    # module's fail_json(msg=..., rc=, cmd=) - kwargs lead, failed/msg
    # follow, the controller adds no *_lines (no stdout/stderr kwargs).
    private def x509_digest(openssl_bin : String, cert_file : String) : (String | PluginResult)
      tmp_out = File.tempname("java-cert-x509")
      begin
        extract_argv = PluginHelpers::JavaCertCommand.extract_x509_cmd(openssl_bin, cert_file, tmp_out)
        extract = remote_exec(extract_argv.join(' '))
        if extract[:exit_code] != 0
          extract_argv = PluginHelpers::JavaCertCommand.extract_x509_cmd(openssl_bin, cert_file, tmp_out, der_fallback: true)
          extract = remote_exec(extract_argv.join(' '))
          if extract[:exit_code] != 0
            return PluginResult.new(changed: false, failed: true,
              msg: "Internal module failure, cannot extract certificate, error: #{extract[:stderr]}",
              rc: extract[:exit_code], cmd: extract_argv,
              key_order: ["rc", "cmd", "failed", "msg"])
          end
        end

        dgst_argv = PluginHelpers::JavaCertCommand.dgst_cmd(openssl_bin, tmp_out)
        dgst = remote_exec(dgst_argv.join(' '))
        if dgst[:exit_code] != 0
          return PluginResult.new(changed: false, failed: true,
            msg: "Internal module failure, cannot compute digest for certificate, error: #{dgst[:stderr]}",
            rc: dgst[:exit_code], cmd: dgst_argv,
            key_order: ["rc", "cmd", "failed", "msg"])
        end
        dgst[:stdout].split(" ").first? || ""
      ensure
        File.delete(tmp_out) rescue nil
      end
    end

    EXTRA_BIN_DIRS = %w[/sbin /usr/sbin /usr/local/sbin]
    @searched_paths = ""

    # Deferred get_bin_path('openssl', True): the resolved binary path,
    # or the failure result real's own bin lookup produces.
    private def require_openssl : (String | PluginResult)
      script = <<-SH
        found=""
        searched=""
        for d in $(printf '%s' "$PATH" | tr ':' ' ') #{EXTRA_BIN_DIRS.join(' ')}; do
          case ":$searched:" in *":$d:"*) ;; *) searched="${searched:+$searched:}$d" ;; esac
          if [ -z "$found" ] && [ -x "$d/openssl" ]; then found="$d/openssl"; fi
        done
        printf '%s\n%s' "$found" "$searched"
        SH

      result = remote_exec(script)
      found, _, searched = result[:stdout].to_s.partition("\n")
      found = found.strip
      searched = searched.strip
      @searched_paths = searched
      return found unless found.empty?
      failed_result(PluginHelpers::RunCommandFailure.bin_path_missing("openssl", @searched_paths))
    end

    private def failed_result(msg : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: msg)
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::JavaCertPlugin.new(config)
plugin.run
