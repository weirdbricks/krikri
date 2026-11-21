require "../minitest_helper"
require "../../src/krikri/ssm_settings"
require "../../src/krikri/host"

module SsmSettingsSpecHelper
  ENV_KEYS = %w[
    AWS_REGION AWS_DEFAULT_REGION AWS_PROFILE AWS_DEFAULT_PROFILE
    AWS_ACCESS_KEY_ID AWS_ACCESS_KEY AWS_SECRET_ACCESS_KEY AWS_SECRET_KEY
    AWS_SESSION_TOKEN AWS_SESSION_MANAGER_PLUGIN
  ]

  def self.host(name : String, vars : Hash(String, JSON::Any) = Hash(String, JSON::Any).new) : Krikri::Host
    host = Krikri::Host.new(name)
    host.vars = vars
    host
  end

  def self.jv(value : String) : JSON::Any
    JSON::Any.new(value)
  end

  def self.with_clean_aws_env(values : Hash(String, String?), &)
    previous = {} of String => String?
    ENV_KEYS.each { |key| previous[key] = ENV[key]? }
    ENV_KEYS.each { |key| ENV.delete(key) }
    values.each do |key, value|
      if value
        ENV[key] = value
      else
        ENV.delete(key)
      end
    end
    begin
      yield
    ensure
      previous.each do |key, value|
        if value
          ENV[key] = value
        else
          ENV.delete(key)
        end
      end
    end
  end
end

describe Krikri::SsmSettings do
  serial!

  it "uses the instance id, then ansible_host, then the inventory name" do
    SsmSettingsSpecHelper.with_clean_aws_env({} of String => String?) do
      with_id = Krikri::SsmSettings.resolve(SsmSettingsSpecHelper.host("web1", {
        "ansible_aws_ssm_instance_id" => SsmSettingsSpecHelper.jv("i-0123"),
        "ansible_host"                => SsmSettingsSpecHelper.jv("10.0.0.9"),
      } of String => JSON::Any), nil)
      with_id.target.must_equal("i-0123")

      with_host = Krikri::SsmSettings.resolve(SsmSettingsSpecHelper.host("web2", {
        "ansible_host" => SsmSettingsSpecHelper.jv("10.0.0.9"),
      } of String => JSON::Any), nil)
      with_host.target.must_equal("10.0.0.9")

      Krikri::SsmSettings.resolve(SsmSettingsSpecHelper.host("web3"), nil).target.must_equal("web3")
    end
  end

  it "prefers the task vars context over the host's inventory vars" do
    SsmSettingsSpecHelper.with_clean_aws_env({} of String => String?) do
      host = SsmSettingsSpecHelper.host("web1", {
        "ansible_aws_ssm_region"  => SsmSettingsSpecHelper.jv("us-west-2"),
        "ansible_aws_ssm_timeout" => JSON::Any.new(10),
      } of String => JSON::Any)
      settings = Krikri::SsmSettings.resolve(host, {
        "ansible_aws_ssm_region"  => SsmSettingsSpecHelper.jv("eu-west-1"),
        "ansible_aws_ssm_timeout" => JSON::Any.new(15),
      } of String => JSON::Any)
      settings.region.must_equal("eu-west-1")
      settings.timeout.must_equal(15)
    end
  end

  it "falls back to AWS_REGION then AWS_DEFAULT_REGION then us-east-1" do
    SsmSettingsSpecHelper.with_clean_aws_env({"AWS_REGION" => "eu-central-1", "AWS_DEFAULT_REGION" => "ap-south-1"}) do
      Krikri::SsmSettings.resolve(SsmSettingsSpecHelper.host("web1"), nil).region.must_equal("eu-central-1")
    end
    SsmSettingsSpecHelper.with_clean_aws_env({"AWS_DEFAULT_REGION" => "ap-south-1"}) do
      Krikri::SsmSettings.resolve(SsmSettingsSpecHelper.host("web1"), nil).region.must_equal("ap-south-1")
    end
    SsmSettingsSpecHelper.with_clean_aws_env({} of String => String?) do
      Krikri::SsmSettings.resolve(SsmSettingsSpecHelper.host("web1"), nil).region.must_equal("us-east-1")
    end
  end

  it "falls back to AWS_PROFILE then AWS_DEFAULT_PROFILE" do
    SsmSettingsSpecHelper.with_clean_aws_env({"AWS_PROFILE" => "prod", "AWS_DEFAULT_PROFILE" => "fallback"}) do
      Krikri::SsmSettings.resolve(SsmSettingsSpecHelper.host("web1"), nil).profile.must_equal("prod")
    end
    SsmSettingsSpecHelper.with_clean_aws_env({"AWS_DEFAULT_PROFILE" => "fallback"}) do
      Krikri::SsmSettings.resolve(SsmSettingsSpecHelper.host("web1"), nil).profile.must_equal("fallback")
    end
    SsmSettingsSpecHelper.with_clean_aws_env({} of String => String?) do
      Krikri::SsmSettings.resolve(SsmSettingsSpecHelper.host("web1"), nil).profile.must_be_nil
    end
  end

  it "takes the documented timeout and retry defaults" do
    SsmSettingsSpecHelper.with_clean_aws_env({} of String => String?) do
      settings = Krikri::SsmSettings.resolve(SsmSettingsSpecHelper.host("web1"), nil)
      settings.timeout.must_equal(60)
      settings.retries.must_equal(3)
    end
  end

  it "reads static credentials from the SSM options, aliases and env in order" do
    SsmSettingsSpecHelper.with_clean_aws_env({
      "AWS_ACCESS_KEY_ID"     => "env-access",
      "AWS_SECRET_ACCESS_KEY" => "env-secret",
      "AWS_SESSION_TOKEN"     => "env-token",
    }) do
      from_aliases = Krikri::SsmSettings.resolve(SsmSettingsSpecHelper.host("web1", {
        "aws_access_key_id"     => SsmSettingsSpecHelper.jv("alias-access"),
        "aws_secret_access_key" => SsmSettingsSpecHelper.jv("alias-secret"),
      } of String => JSON::Any), nil)
      from_aliases.access_key_id.must_equal("alias-access")
      from_aliases.secret_access_key.must_equal("alias-secret")

      from_canonical = Krikri::SsmSettings.resolve(SsmSettingsSpecHelper.host("web1", {
        "ansible_aws_ssm_access_key_id"     => SsmSettingsSpecHelper.jv("canonical-access"),
        "aws_access_key_id"                 => SsmSettingsSpecHelper.jv("alias-access"),
        "ansible_aws_ssm_secret_access_key" => SsmSettingsSpecHelper.jv("canonical-secret"),
        "aws_secret_access_key"             => SsmSettingsSpecHelper.jv("alias-secret"),
        "ansible_aws_ssm_session_token"     => SsmSettingsSpecHelper.jv("canonical-token"),
      } of String => JSON::Any), nil)
      from_canonical.access_key_id.must_equal("canonical-access")
      from_canonical.secret_access_key.must_equal("canonical-secret")
      from_canonical.session_token.must_equal("canonical-token")

      from_env = Krikri::SsmSettings.resolve(SsmSettingsSpecHelper.host("web1"), nil)
      from_env.access_key_id.must_equal("env-access")
      from_env.secret_access_key.must_equal("env-secret")
      from_env.session_token.must_equal("env-token")
    end
  end

  it "accepts and warns once for each ignored Ansible option" do
    SsmSettingsSpecHelper.with_clean_aws_env({} of String => String?) do
      settings = Krikri::SsmSettings.resolve(SsmSettingsSpecHelper.host("web1", {
        "ansible_aws_ssm_plugin"              => SsmSettingsSpecHelper.jv("/usr/local/bin/session-manager-plugin"),
        "ansible_aws_ssm_bucket_name"         => SsmSettingsSpecHelper.jv("my-bucket"),
        "ansible_aws_ssm_s3_addressing_style" => SsmSettingsSpecHelper.jv("virtual"),
      } of String => JSON::Any), nil)
      settings.ignored_options.must_equal([
        "ansible_aws_ssm_plugin",
        "ansible_aws_ssm_bucket_name",
        "s3_addressing_style",
      ])
      warnings = settings.ignored_warnings
      warnings.size.must_equal(3)
      warnings[0].includes?("session-manager-plugin").must_equal(true)
      warnings[1].includes?("S3").must_equal(true)
      warnings[2].includes?("S3").must_equal(true)
    end
  end

  it "recognizes Windows-flavoured targets and exposes the unsupported message" do
    SsmSettingsSpecHelper.with_clean_aws_env({} of String => String?) do
      shell = Krikri::SsmSettings.resolve(SsmSettingsSpecHelper.host("web1", {
        "ansible_shell_type" => SsmSettingsSpecHelper.jv("powershell"),
      } of String => JSON::Any), nil)
      shell.windows_target?.must_equal(true)
      shell.windows_unsupported_message.must_equal(Krikri::SsmSettings::WINDOWS_UNSUPPORTED_MESSAGE)

      document = Krikri::SsmSettings.resolve(SsmSettingsSpecHelper.host("web1", {
        "ansible_aws_ssm_document" => SsmSettingsSpecHelper.jv("AWS-StartPowerShellSession"),
      } of String => JSON::Any), nil)
      document.windows_target?.must_equal(true)

      facts = Krikri::SsmSettings.resolve(SsmSettingsSpecHelper.host("web1", {
        "ansible_os_family" => SsmSettingsSpecHelper.jv("Windows"),
      } of String => JSON::Any), nil)
      facts.windows_target?.must_equal(true)

      linux = Krikri::SsmSettings.resolve(SsmSettingsSpecHelper.host("web1"), nil)
      linux.windows_target?.must_equal(false)
    end
  end

  it "keys the session identity on the settings that change it" do
    SsmSettingsSpecHelper.with_clean_aws_env({} of String => String?) do
      base = Krikri::SsmSettings.new("i-0123", region: "us-east-1")
      same = Krikri::SsmSettings.new("i-0123", region: "us-east-1")
      other_region = Krikri::SsmSettings.new("i-0123", region: "us-west-2")
      other_document = Krikri::SsmSettings.new("i-0123", region: "us-east-1", document: "SSM-SessionManagerRunShell")

      base.identity_key.must_equal(same.identity_key)
      base.identity_key.wont_equal(other_region.identity_key)
      base.identity_key.wont_equal(other_document.identity_key)
    end
  end

  it "flags an http endpoint as intentionally insecure" do
    SsmSettingsSpecHelper.with_clean_aws_env({} of String => String?) do
      http = Krikri::SsmSettings.new("i-0123", endpoint_url: "http://127.0.0.1:4566")
      https = Krikri::SsmSettings.new("i-0123", endpoint_url: "https://ssm.us-east-1.amazonaws.com")
      http.insecure_endpoint?.must_equal(true)
      https.insecure_endpoint?.must_equal(false)
    end
  end
end
