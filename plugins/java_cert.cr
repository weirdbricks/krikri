#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/java_cert_command"

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
    def execute : PluginResult
      url = @params["cert_url"]?
      path = @params["cert_path"]?
      content = @params["cert_content"]?
      port = (@params["cert_port"]? || "443").to_i? || 443

      pkcs12_path = @params["pkcs12_path"]?
      pkcs12_pass = @params["pkcs12_password"]? || ""
      pkcs12_alias = @params["pkcs12_alias"]? || "1"

      cert_alias = @params["cert_alias"]? || url
      trust_cacert = true?(@params["trust_cacert"]?)
      keystore_path = @params["keystore_path"]?
      keystore_pass = @params["keystore_pass"]?
      keystore_create = true?(@params["keystore_create"]?)
      keystore_type = @params["keystore_type"]?
      executable = @params["executable"]? || "keytool"
      state = @params["state"]? || "present"

      return failed_result("Unsupported parameters for (java_cert) module: state must be 'present' or 'absent'") unless ["present", "absent"].includes?(state)
      return failed_result("missing required arguments: keystore_pass") unless keystore_pass
      keystore_path ||= ""

      sources = [url, path, content, pkcs12_path].compact
      if state == "present" && sources.empty?
        return failed_result("state is present but any of the following is missing: cert_path, cert_url, cert_content, pkcs12_path")
      end
      if state == "absent" && !url && !cert_alias
        return failed_result("state is absent but any of the following is missing: cert_url, cert_alias")
      end
      if sources.size > 1
        return failed_result("parameters are mutually exclusive: cert_url|cert_path|cert_content|pkcs12_path")
      end

      if path && !cert_alias
        return failed_result("Using local path import from #{keystore_path} requires alias argument.")
      end
      if state == "present" && !cert_alias
        return failed_result("Using pkcs12/content import requires cert_alias argument.")
      end

      openssl_bin = find_openssl
      return failed_result("Failed to find required executable openssl in the paths.") unless openssl_bin

      keytool_check = remote_exec(executable)
      return failed_result("Failed to find required executable #{executable} in the paths.") unless keytool_check[:exit_code] == 0

      if !keystore_create && !keystore_path.empty? && !remote_file_exists?(keystore_path)
        return PluginResult.new(changed: false, failed: true,
          msg: "Module require existing keystore at keystore_path '#{keystore_path}'")
      end

      check_mode = true?(@params["check_mode"]?)
      keystore_pass_str = keystore_pass.not_nil!

      alias_exists, alias_exists_output = check_cert_present(executable, keystore_path, keystore_pass_str, cert_alias || "", keystore_type)

      if state == "absent"
        if alias_exists
          return PluginResult.new(changed: true, failed: false, msg: "Certificate delete complete.") if check_mode
          return delete_cert(executable, keystore_path, keystore_pass_str, cert_alias.not_nil!, keystore_type)
        end
        return PluginResult.new(changed: false, failed: false, msg: "Certificate not present.")
      end

      cert_alias_str = cert_alias.not_nil!

      keystore_cert_digest = ""
      if alias_exists
        old_tmp = File.tempname("java-cert-old")
        File.write(old_tmp, alias_exists_output)
        digest = x509_digest(openssl_bin, old_tmp)
        File.delete(old_tmp) rescue nil
        return digest if digest.is_a?(PluginResult)
        keystore_cert_digest = digest.as(String)
      end

      new_tmp = File.tempname("java-cert-new")
      cleanup = true
      begin
        if pkcs12_path
          export = remote_exec(PluginHelpers::JavaCertCommand.with_stdin(
            PluginHelpers::JavaCertCommand.export_pkcs12_cmd(executable, pkcs12_path, pkcs12_alias), [pkcs12_pass]
          ))
          return PluginResult.new(changed: false, failed: true,
            msg: "Internal module failure, cannot extract public certificate from PKCS12, message: #{export[:stdout]}",
            stderr: export[:stderr]) unless export[:exit_code] == 0
          File.write(new_tmp, export[:stdout])
        elsif path
          new_tmp = path.not_nil!
          cleanup = false
        elsif content
          File.write(new_tmp, content.not_nil!)
        elsif url
          fetch = remote_exec(PluginHelpers::JavaCertCommand.fetch_url_cmd(
            executable, url.not_nil!, port,
            PluginHelpers::JavaCertCommand.proxy_opts(ENV["https_proxy"]?, ENV["no_proxy"]?)
          ))
          return PluginResult.new(changed: false, failed: true,
            msg: "Internal module failure, cannot download certificate, error: #{fetch[:stderr]}",
            cmd: PluginHelpers::JavaCertCommand.fetch_url_cmd(executable, url.not_nil!, port, [] of String)) unless fetch[:exit_code] == 0
          File.write(new_tmp, fetch[:stdout])
        end

        new_digest = x509_digest(openssl_bin, new_tmp)
        return new_digest if new_digest.is_a?(PluginResult)

        if keystore_cert_digest != new_digest
          return PluginResult.new(changed: true, failed: false, msg: "Certificate import complete.") if check_mode

          if alias_exists
            delete_result = delete_cert(executable, keystore_path, keystore_pass_str, cert_alias_str, keystore_type)
            return delete_result if delete_result.failed?
          end

          if pkcs12_path
            return import_pkcs12(executable, pkcs12_path.not_nil!, pkcs12_pass, pkcs12_alias,
              keystore_path, keystore_pass_str, cert_alias_str, keystore_type)
          else
            return import_cert(executable, new_tmp, keystore_path, keystore_pass_str, cert_alias_str, keystore_type, trust_cacert)
          end
        end

        PluginResult.new(changed: false, failed: false, msg: "Certificate already present.",
          cmd: PluginHelpers::JavaCertCommand.check_cmd(executable, keystore_path, cert_alias_str, keystore_type))
      ensure
        File.delete(new_tmp) rescue nil if cleanup
      end
    end

    private def check_cert_present(executable : String, keystore_path : String, keystore_pass : String,
                                   cert_alias : String, keystore_type : String?) : {Bool, String}
      return {false, ""} if keystore_path.empty?
      command = PluginHelpers::JavaCertCommand.with_stdin(
        PluginHelpers::JavaCertCommand.check_cmd(executable, keystore_path, cert_alias, keystore_type), [keystore_pass]
      )
      result = remote_exec(command)
      result[:exit_code] == 0 ? {true, result[:stdout]} : {false, ""}
    end

    private def delete_cert(executable : String, keystore_path : String, keystore_pass : String,
                            cert_alias : String, keystore_type : String?) : PluginResult
      command = PluginHelpers::JavaCertCommand.with_stdin(
        PluginHelpers::JavaCertCommand.delete_cmd(executable, keystore_path, cert_alias, keystore_type), [keystore_pass]
      )
      result = remote_exec(command)
      diff = JSON.parse({before: "#{cert_alias}\n", after: nil}.to_json)
      return PluginResult.new(changed: false, failed: true, msg: result[:stdout], stderr: result[:stderr], cmd: command) unless result[:exit_code] == 0
      PluginResult.new(changed: true, failed: false, msg: result[:stdout].strip, diff: diff)
    end

    private def import_cert(executable : String, cert_path : String, keystore_path : String, keystore_pass : String,
                            cert_alias : String, keystore_type : String?, trust_cacert : Bool) : PluginResult
      command = PluginHelpers::JavaCertCommand.with_stdin(
        PluginHelpers::JavaCertCommand.import_cert_cmd(executable, cert_path, keystore_path, cert_alias, keystore_type, trust_cacert),
        [keystore_pass, keystore_pass]
      )
      result = remote_exec(command)
      diff = JSON.parse({before: "\n", after: "#{cert_alias}\n"}.to_json)
      return PluginResult.new(changed: false, failed: true, msg: result[:stdout], stderr: result[:stderr], cmd: command) unless result[:exit_code] == 0
      PluginResult.new(changed: true, failed: false, msg: result[:stdout].strip, diff: diff)
    end

    private def import_pkcs12(executable : String, pkcs12_path : String, pkcs12_pass : String, pkcs12_alias : String,
                              keystore_path : String, keystore_pass : String, cert_alias : String,
                              keystore_type : String?) : PluginResult
      command = PluginHelpers::JavaCertCommand.with_stdin(
        PluginHelpers::JavaCertCommand.import_pkcs12_cmd(executable, pkcs12_path, pkcs12_alias, keystore_path, cert_alias, keystore_type),
        keystore_path.empty? || !remote_file_exists?(keystore_path) ? [keystore_pass, keystore_pass, keystore_pass] : [keystore_pass, pkcs12_pass]
      )
      result = remote_exec(command)
      diff = JSON.parse({before: "\n", after: "#{cert_alias}\n"}.to_json)
      return PluginResult.new(changed: false, failed: true, msg: result[:stdout], stderr: result[:stderr], cmd: command) unless result[:exit_code] == 0
      PluginResult.new(changed: true, failed: false, msg: result[:stdout].strip, diff: diff)
    end

    # _get_digest_from_x509_file: extract the first certificate from
    # the chain (PEM, DER fallback), then sha256 it. Returns the hex
    # digest, or a failure result.
    private def x509_digest(openssl_bin : String, cert_file : String) : (String | PluginResult)
      tmp_out = File.tempname("java-cert-x509")
      begin
        extract = remote_exec(PluginHelpers::JavaCertCommand.extract_x509_cmd(openssl_bin, cert_file, tmp_out))
        if extract[:exit_code] != 0
          extract = remote_exec(PluginHelpers::JavaCertCommand.extract_x509_cmd(openssl_bin, cert_file, tmp_out, der_fallback: true))
          if extract[:exit_code] != 0
            return PluginResult.new(changed: false, failed: true,
              msg: "Internal module failure, cannot extract certificate, error: #{extract[:stderr]}")
          end
        end

        dgst = remote_exec(PluginHelpers::JavaCertCommand.dgst_cmd(openssl_bin, tmp_out))
        if dgst[:exit_code] != 0
          return PluginResult.new(changed: false, failed: true,
            msg: "Internal module failure, cannot compute digest for certificate, error: #{dgst[:stderr]}")
        end
        dgst[:stdout].split(" ").first? || ""
      ensure
        File.delete(tmp_out) rescue nil
      end
    end

    private def find_openssl : String?
      # `command -v` would be argv-split by LocalExecutor (a shell
      # builtin with no shell metacharacters in the string) - probe
      # with a real openssl invocation instead.
      result = remote_exec("openssl version >/dev/null 2>&1")
      result[:exit_code] == 0 ? "openssl" : nil
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
