require "json"
require "digest/sha1"
require "./host"

module Krikri
  # The resolved AWS SSM connection options for one dispatch.
  #
  # Values come from the same two tiers ConnectionSettings uses: the
  # task's rendered vars context first (task > block > play > many layers,
  # already merged by build_vars_context), then the host's raw inventory
  # vars. Environment fallbacks sit below both, exactly where Ansible's
  # aws_ssm connection plugin puts them.
  #
  # The SSM connection has no login user: `ansible_user` is not an
  # identity here (Ansible's plugin documents this), only
  # `become_user` switches privileges on the target. The actual session
  # OS user is the document's run-as user (ssm-user by default), see
  # SsmSettings::SESSION_OS_USER and ConnectionSettings#staging_user.
  struct SsmSettings
    DEFAULT_REGION  = "us-east-1"
    DEFAULT_TIMEOUT = 60
    DEFAULT_RETRIES =  3

    # The OS user a standard Session Manager shell document runs as.
    # krikri stages its plugin binaries under this identity rather than
    # ansible_user, so a later SSH run (as root/admin) cannot collide
    # with the SSM run's /var/tmp staging tree.
    SESSION_OS_USER = "ssm-user"

    # No Windows transport exists in krikri (no winrm/psrp either), so a
    # PowerShell-flavoured target fails before any session is opened.
    WINDOWS_UNSUPPORTED_MESSAGE =
      "Windows targets are not supported over aws_ssm (krikri-playbook has no Windows transport)"

    # v1 limits (plan sections 6.6 and 14): both fail cleanly rather than
    # half-working over a pty session that the agent can reap.
    ASYNC_UNSUPPORTED_MESSAGE       = "async is not supported over aws_ssm yet"
    SYNCHRONIZE_UNSUPPORTED_MESSAGE = "synchronize is not supported over aws_ssm yet"

    getter target : String
    getter region : String
    getter profile : String?
    getter document : String?
    getter timeout : Int32
    getter retries : Int32
    getter endpoint_url : String?
    getter access_key_id : String?
    getter secret_access_key : String?
    getter session_token : String?
    getter shell_type : String?
    getter ignored_options : Array(String)
    getter? windows_vars : Bool

    def initialize(@target : String, @region : String = DEFAULT_REGION,
                   @profile : String? = nil, @document : String? = nil,
                   @timeout : Int32 = DEFAULT_TIMEOUT, @retries : Int32 = DEFAULT_RETRIES,
                   @endpoint_url : String? = nil, @access_key_id : String? = nil,
                   @secret_access_key : String? = nil, @session_token : String? = nil,
                   @shell_type : String? = nil, @ignored_options : Array(String) = [] of String,
                   @windows_vars : Bool = false)
    end

    def self.resolve(host : Host, vars : Hash(String, JSON::Any)?) : SsmSettings
      instance_id = tiered_var(vars, host, "ansible_aws_ssm_instance_id")
      target = instance_id || tiered_var(vars, host, "ansible_host") || host.name

      region = tiered_var(vars, host, "ansible_aws_ssm_region") ||
               env_first("AWS_REGION", "AWS_DEFAULT_REGION") ||
               DEFAULT_REGION
      profile = tiered_var(vars, host, "ansible_aws_ssm_profile") ||
                env_first("AWS_PROFILE", "AWS_DEFAULT_PROFILE")
      document = tiered_var(vars, host, "ansible_aws_ssm_document")
      timeout = tiered_int(vars, host, "ansible_aws_ssm_timeout") || DEFAULT_TIMEOUT
      retries = tiered_int(vars, host, "ansible_aws_ssm_retries") || DEFAULT_RETRIES
      endpoint_url = tiered_var(vars, host, "ansible_aws_ssm_endpoint_url")

      access_key_id, secret_access_key, session_token = credential_options(vars, host)

      shell_type = tiered_var(vars, host, "ansible_shell_type")

      new(target, region, profile, document, timeout, retries, endpoint_url,
        access_key_id, secret_access_key, session_token, shell_type,
        ignored_options(vars, host), windows_vars?(vars, host))
    end

    private def self.credential_options(vars : Hash(String, JSON::Any)?, host : Host) : {String?, String?, String?}
      access_key_id = tiered_var(vars, host, "ansible_aws_ssm_access_key_id", "aws_access_key_id") ||
                      env_first("AWS_ACCESS_KEY_ID", "AWS_ACCESS_KEY")
      secret_access_key = tiered_var(vars, host, "ansible_aws_ssm_secret_access_key", "aws_secret_access_key") ||
                          env_first("AWS_SECRET_ACCESS_KEY", "AWS_SECRET_KEY")
      session_token = tiered_var(vars, host, "ansible_aws_ssm_session_token") ||
                      env_first("AWS_SESSION_TOKEN")
      {access_key_id, secret_access_key, session_token}
    end

    private def self.ignored_options(vars : Hash(String, JSON::Any)?, host : Host) : Array(String)
      ignored = [] of String
      plugin = tiered_var(vars, host, "ansible_aws_ssm_plugin") ||
               env_first("AWS_SESSION_MANAGER_PLUGIN")
      ignored << "ansible_aws_ssm_plugin" if plugin
      ignored << "ansible_aws_ssm_bucket_name" if tiered_var(vars, host, "ansible_aws_ssm_bucket_name")
      if tiered_var(vars, host, "ansible_aws_ssm_s3_addressing_style") ||
         tiered_var(vars, host, "s3_addressing_style")
        ignored << "s3_addressing_style"
      end
      ignored
    end

    private def self.windows_vars?(vars : Hash(String, JSON::Any)?, host : Host) : Bool
      %w[ansible_os_family ansible_system].any? do |key|
        tiered_var(vars, host, key).try(&.downcase.in?("windows"))
      end
    end

    # A PowerShell/cmd shell document or Windows facts make this an
    # unsupported target. krikri must refuse it before dialing a shell it
    # cannot drive.
    def windows_target? : Bool
      return true if windows_vars?
      shell = @shell_type.try(&.downcase)
      return true if shell && (shell == "powershell" || shell == "pwsh" || shell == "cmd")

      document = @document.try(&.downcase) || ""
      document.includes?("powershell") || document.includes?("windows")
    end

    def windows_unsupported_message : String
      WINDOWS_UNSUPPORTED_MESSAGE
    end

    # A plain insecure endpoint is an explicit test/VPC endpoint. The
    # shard refuses ws:// unless this flag says the caller meant it.
    def insecure_endpoint? : Bool
      url = @endpoint_url
      return false unless url
      url.starts_with?("http://") || url.starts_with?("ws://")
    end

    # Static credentials from the connection options/env, or nil to let
    # the shard's CredentialChain resolve them (profile/SSO/IMDS/...).
    def static_credentials
      access = @access_key_id
      secret = @secret_access_key
      return nil unless access && secret
      {access_key: access, secret_key: secret, session_token: @session_token}
    end

    # The one warning each ignored Ansible option emits (deduped by the
    # display layer, so repeated resolves still print once per run).
    def ignored_warnings : Array(String)
      @ignored_options.map do |option|
        case option
        when "ansible_aws_ssm_plugin"
          "Ignoring ansible_aws_ssm_plugin: krikri-playbook never uses session-manager-plugin"
        when "ansible_aws_ssm_bucket_name"
          "Ignoring ansible_aws_ssm_bucket_name: krikri-playbook never stages files through S3"
        else
          "Ignoring #{option}: krikri-playbook never stages files through S3"
        end
      end
    end

    # Stable identity of every setting that changes which session this
    # dispatch needs. Two inventory names for one instance resolve to the
    # same identity but still key separately by host; a task-level flip to
    # a different region/document/credential set changes the key and gets
    # its own session. The secret is hashed, never stored in the key.
    def identity_key : String
      Digest::SHA1.hexdigest([
        @target, @region, @profile.to_s, @document.to_s, @endpoint_url.to_s,
        @timeout.to_s, @retries.to_s,
        @access_key_id.to_s,
        @secret_access_key.try { |secret| Digest::SHA1.hexdigest(secret) } || "",
        @session_token.to_s,
      ].join('\u{0}'))
    end

    private def self.tiered_var(vars : Hash(String, JSON::Any)?, host : Host,
                                key : String, alias_key : String? = nil) : String?
      string_var(vars, key) ||
        (alias_key ? string_var(vars, alias_key) : nil) ||
        string_var(host.vars, key) ||
        (alias_key ? string_var(host.vars, alias_key) : nil)
    end

    private def self.tiered_int(vars : Hash(String, JSON::Any)?, host : Host, key : String) : Int32?
      int_var(vars, key) || int_var(host.vars, key)
    end

    private def self.string_var(vars : Hash(String, JSON::Any)?, key : String) : String?
      value = vars.try(&.[key]?)
      return nil unless value
      text = value.as_s?
      return nil if text.nil? || text.empty?
      return nil if text.includes?("{{") || text.includes?("{%")
      text
    end

    private def self.int_var(vars : Hash(String, JSON::Any)?, key : String) : Int32?
      value = vars.try(&.[key]?)
      return nil unless value
      return nil if value.as_s?.try { |text| text.includes?("{{") || text.includes?("{%") }
      parsed = value.as_i? || value.as_s?.try(&.to_i?)
      return nil unless parsed
      positive = parsed.positive? ? parsed : nil
      positive.try(&.to_i32)
    end

    private def self.env_first(*names : String) : String?
      names.each do |name|
        value = ENV[name]?.presence
        return value if value
      end
      nil
    end
  end
end
