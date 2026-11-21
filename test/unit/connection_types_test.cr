require "../minitest_helper"
require "../../src/krikri/plugin_manager"
require "../../src/krikri/connection_types"
require "../../src/krikri/host"

private def conn_types_tmp(name : String) : String
  path = PluginSpecHelper.tmp_path(name)
  FileUtils.rm_rf(path) if Dir.exists?(path)
  Dir.mkdir_p(path)
  path
end

private def with_env_values(values : Hash(String, String?), &) : Nil
  previous = {} of String => String?
  values.each_key do |key|
    previous[key] = ENV[key]?
  end
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

describe Krikri::ConnectionTypes do
  it "treats every aws_ssm spelling as SSM without asking the loader" do
    Krikri::ConnectionTypes::SSM_CONNECTION_TYPES.each do |name|
      Krikri::ConnectionTypes.ssm?(name).must_equal(true)
      Krikri::ConnectionTypes.builtin?(name).must_equal(true)
      Krikri::ConnectionTypes.transport(name).must_equal("ssm")
      Krikri::ConnectionTypes.local?(name).must_equal(false)
    end
  end

  it "keeps the existing local and ssh transports unchanged" do
    Krikri::ConnectionTypes.transport("local").must_equal("local")
    Krikri::ConnectionTypes.transport("ansible.builtin.local").must_equal("local")
    Krikri::ConnectionTypes.transport("ssh").must_equal("ssh")
    Krikri::ConnectionTypes.transport("smart").must_equal("ssh")
    Krikri::ConnectionTypes.transport("winrm").must_equal("ssh")
  end

  it "lets the rendered vars context win over inventory for the connection type" do
    host = Krikri::Host.new("web", nil, nil)
    host.vars = {"ansible_connection" => JSON::Any.new("ssh")}
    vars = {"ansible_connection" => JSON::Any.new("amazon.aws.aws_ssm")}

    Krikri::ConnectionTypes.resolved_name(host, vars).must_equal("amazon.aws.aws_ssm")
    Krikri::ConnectionTypes.ssm_name(host, vars).must_equal("amazon.aws.aws_ssm")

    reverse = Krikri::Host.new("web", nil, nil)
    reverse.vars = {"ansible_connection" => JSON::Any.new("amazon.aws.aws_ssm")}
    Krikri::ConnectionTypes.resolved_name(reverse, {"ansible_connection" => JSON::Any.new("ssh")}).must_equal("ssh")
    Krikri::ConnectionTypes.ssm_name(reverse, {"ansible_connection" => JSON::Any.new("ssh")}).must_be_nil
  end

  it "falls back to the inventory setting when the context has none" do
    host = Krikri::Host.new("web", nil, nil)
    host.vars = {"ansible_connection" => JSON::Any.new("aws_ssm")}
    Krikri::ConnectionTypes.resolved_name(host, Hash(String, JSON::Any).new).must_equal("aws_ssm")
  end

  it "reports a custom connection plugin as resolved but unsupported" do
    dir = conn_types_tmp("connection_types_custom")
    Dir.mkdir_p(File.join(dir, "connection_plugins"))
    File.write(File.join(dir, "connection_plugins", "custom.py"), "# a plugin\n")

    Krikri::ConnectionTypes.transport("custom", dir).must_equal("ssh")
    Krikri::ConnectionTypes.not_found?("custom", dir).must_equal(false)
    Krikri::ConnectionTypes.unsupported?("custom", dir).must_equal(true)
    Krikri::PluginManager.connection_plugin_unsupported?("custom", dir).must_equal(true)
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end

  it "still reports an unknown name as not found" do
    dir = conn_types_tmp("connection_types_unknown")
    Krikri::ConnectionTypes.not_found?("no_such_connection", dir).must_equal(true)
    Krikri::PluginManager.connection_plugin_not_found?("no_such_connection", dir).must_equal(true)
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end

  describe "with an installed collection" do
    serial!

    it "keeps the SSM aliases on the SSM transport" do
      root = conn_types_tmp("connection_types_collection")
      plugin_dir = File.join(root, "ansible_collections", "amazon", "aws",
        "plugins", "connection")
      Dir.mkdir_p(plugin_dir)
      File.write(File.join(plugin_dir, "aws_ssm.py"), "# fake installed collection plugin\n")

      with_env_values({"ANSIBLE_COLLECTIONS_PATH" => root}) do
        Krikri::ConnectionTypes::SSM_CONNECTION_TYPES.each do |name|
          Krikri::ConnectionTypes.transport(name, root).must_equal("ssm")
          Krikri::PluginManager.connection_plugin_transport(name, root).must_equal("ssm")
          Krikri::PluginManager.connection_plugin_unsupported?(name, root).must_equal(false)
        end
      end
    ensure
      FileUtils.rm_rf(root) if root && Dir.exists?(root)
    end
  end
end
