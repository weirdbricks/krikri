require "../spec_helper"

# Real bug found benchmarking robertdebock.redis (round 40, 0.9.385):
# `mode: "{{ redis_mode }}"` rendered to the plain templated string
# "640" (no leading zero - it comes from a Jinja dict-lookup default,
# not a literal YAML octal like `mode: "0640"`). template.cr/copy.cr/
# ini_file.cr all shared the same `mode.starts_with?("0") ? octal :
# decimal` branch, so a leading-zero-less digit string was parsed as
# DECIMAL 640 and then handed straight to File.chmod - producing octal
# 1200 (`--w------T`) instead of the intended 0640 (`rw-r-----`).
# Real Ansible parses ANY all-digit mode string as octal regardless of
# a leading zero. This left redis-server unable to even read its own
# rendered /etc/redis/redis.conf, crash-looping on real Atlantic.net
# hosts. file.cr's own `parse_numeric_mode` already got this right;
# these three plugins now match it.
describe "mode: string parsing (no leading zero)" do
  it "template plugin treats a leading-zero-less digit mode: string as octal, not decimal" do
    dest = File.tempname("template-mode-spec")

    result = PluginSpecHelper.run("template", {"content" => "hello\n", "dest" => dest, "mode" => "640"})

    result["changed"].as_bool.should be_true
    (File.info(dest).permissions.value & 0o777).should eq(0o640)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "copy plugin treats a leading-zero-less digit mode: string as octal, not decimal" do
    dest = File.tempname("copy-mode-spec")

    result = PluginSpecHelper.run("copy", {"content" => "hello\n", "dest" => dest, "mode" => "640"})

    result["changed"].as_bool.should be_true
    (File.info(dest).permissions.value & 0o777).should eq(0o640)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "ini_file plugin treats a leading-zero-less digit mode: string as octal, not decimal" do
    dest = File.tempname("ini-file-mode-spec")
    File.delete(dest) if File.exists?(dest)

    result = PluginSpecHelper.run("ini_file", {"path" => dest, "section" => "s", "option" => "o", "value" => "v", "mode" => "640"})

    result["changed"].as_bool.should be_true
    (File.info(dest).permissions.value & 0o777).should eq(0o640)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end
end
