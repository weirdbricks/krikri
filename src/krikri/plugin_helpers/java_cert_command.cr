module Krikri
  module PluginHelpers
    # JavaCertCommand - builds the keytool/openssl command lines
    # community.general.java_cert runs, mirroring the real module's
    # helpers (_check_cert_present, delete_cert, import_cert_path,
    # import_pkcs12_path, _export_public_cert_from_pkcs12,
    # _download_cert_url, _get_digest_from_x509_file, and
    # build_proxy_options). Pure string plumbing so the exact argv
    # shapes are unit-testable without a JVM (or a keystore); the
    # plugin itself executes them.
    module JavaCertCommand
      # _get_keystore_type_keytool_parameters
      def self.keystore_type_params(keystore_type : String?) : Array(String)
        keystore_type ? ["-storetype", keystore_type] : [] of String
      end

      # _check_cert_present: PEM dump of the alias to stdout; the
      # password goes over keytool's stdin, never argv.
      def self.check_cmd(executable : String, keystore_path : String, cert_alias : String, keystore_type : String?) : String
        cmd = [executable, "-list", "-keystore", keystore_path, "-alias", cert_alias, "-rfc"]
        cmd += keystore_type_params(keystore_type)
        cmd.join(' ')
      end

      def self.delete_cmd(executable : String, keystore_path : String, cert_alias : String, keystore_type : String?) : String
        cmd = [executable, "-delete", "-noprompt", "-keystore", keystore_path, "-alias", cert_alias]
        cmd += keystore_type_params(keystore_type)
        cmd.join(' ')
      end

      # import_cert_path
      def self.import_cert_cmd(executable : String, cert_path : String, keystore_path : String,
                               cert_alias : String, keystore_type : String?, trust_cacert : Bool) : String
        cmd = [executable, "-importcert", "-noprompt", "-keystore", keystore_path, "-file", cert_path, "-alias", cert_alias]
        cmd += keystore_type_params(keystore_type)
        cmd << "-trustcacerts" if trust_cacert
        cmd.join(' ')
      end

      # import_pkcs12_path
      def self.import_pkcs12_cmd(executable : String, pkcs12_path : String, pkcs12_alias : String?,
                                 keystore_path : String, cert_alias : String?, keystore_type : String?) : String
        cmd = [executable, "-importkeystore", "-noprompt", "-srcstoretype", "pkcs12",
               "-srckeystore", pkcs12_path, "-destkeystore", keystore_path]
        cmd += ["-destalias", cert_alias] if cert_alias
        cmd += ["-srcalias", pkcs12_alias] if pkcs12_alias
        cmd += keystore_type_params(keystore_type)
        cmd.join(' ')
      end

      # _export_public_cert_from_pkcs12
      def self.export_pkcs12_cmd(executable : String, pkcs12_path : String, pkcs12_alias : String?) : String
        cmd = [executable, "-list", "-noprompt", "-keystore", pkcs12_path, "-storetype", "pkcs12", "-rfc"]
        cmd += ["-alias", pkcs12_alias] if pkcs12_alias
        cmd.join(' ')
      end

      # _download_cert_url
      def self.fetch_url_cmd(executable : String, url : String, port : Int32, proxy_opts : Array(String)) : String
        ([executable, "-printcert", "-rfc", "-sslserver"] + proxy_opts + ["#{url}:#{port}"]).join(' ')
      end

      # _get_digest_from_x509_file's two steps: extract the first
      # certificate (PEM first, DER fallback), then hash it. Split
      # into the two commands so the plugin can branch on the extract
      # rc the way the real module does.
      def self.extract_x509_cmd(openssl_bin : String, cert_file : String, out_file : String, der_fallback : Bool = false) : String
        cmd = [openssl_bin, "x509", "-in", cert_file, "-out", out_file]
        cmd << "-inform" << "der" if der_fallback
        cmd.join(' ')
      end

      def self.dgst_cmd(openssl_bin : String, cert_file : String) : String
        [openssl_bin, "dgst", "-r", "-sha256", cert_file].join(' ')
      end

      # build_proxy_options: honors https_proxy/no_proxy environment
      # variables (the real module reads urllib's getproxies()); Java
      # proxy flags go to the JVM with -J, nonProxyHosts entries are
      # '|' separated with leading dots rewritten to '*.'.
      def self.proxy_opts(https_proxy : String?, no_proxy : String?) : Array(String)
        return [] of String unless https_proxy && !https_proxy.empty?
        host_port = https_proxy.sub(%r{^https?://}, "")
        parts = host_port.split(":")
        return [] of String unless parts.size == 2
        opts = ["-J-Dhttps.proxyHost=#{parts[0]}", "-J-Dhttps.proxyPort=#{parts[1]}"]
        if no_proxy
          non_proxy_hosts = no_proxy.gsub(",", "|")
          non_proxy_hosts = non_proxy_hosts.gsub(/(^|\|)\./, "\\1*.")
          opts << "-J-Dhttp.nonProxyHosts=#{non_proxy_hosts}"
        end
        opts
      end

      # Wraps a command with the stdin data the real module's
      # run_command(data=...) feeds it, via printf piped to the
      # command. Each data string is one line.
      def self.with_stdin(command : String, data : Array(String)) : String
        quoted = data.map { |line| "'" + line.gsub("'", "'\\''") + "'" }
        "printf '%s\\n' #{quoted.join(' ')} | #{command}"
      end
    end
  end
end
