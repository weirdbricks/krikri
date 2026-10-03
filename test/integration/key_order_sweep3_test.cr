require "../minitest_helper"
require "file_utils"

# Registered-result key orders for the alternatives/acl/capabilities/
# debconf/dpkg_selections/dpkg_divert/kernel_blacklist/locale_gen/
# modprobe/mount/filesystem/pam_limits/pamd/seboolean/sefcontext/
# seport/iptables/apt/apt_key/apt_repository/deb822_repository/package/
# yum/dnf/dnf5/rpm_key/yum_repository/htpasswd/make/script/expect/npm/
# gem plugins, pinned to the orders live-verified against real
# ansible-core 2.19.11 by registering each module's result and dumping
# `{{ r | to_json }}` (see key_order_sweep_test.cr for the general
# method; the -v dump sorts alphabetically, so the order is only
# observable programmatically).
#
# The pins cover the keys krikri emits, in real's relative order: real's
# registered result additionally carries controller-appended
# ansible_facts (interpreter discovery) and backfilled failed: false /
# warnings after the module dict, which krikri's module wire omits.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Runs a playbook whose final task copies `{{ r | to_json }}` into a
# file, then returns the dumped object's key order (writing the dump
# through copy: avoids the display layer's JSON escaping entirely).
private def run_registered_dump(yaml : String) : Array(String)
  dump = PluginSpecHelper.tmp_path("key-order-dump3.json")
  playbook = File.tempname("key-order-sweep3", ".yml")
  File.write(playbook, yaml.gsub("KRIKRI_DUMP_PATH", dump))
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  status.success?.must_equal(true)
  JSON.parse(File.read(dump)).as_h.keys
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private def unique_tmp(*parts : String) : String
  PluginSpecHelper.tmp_path("#{parts.join("-")}-#{Random::Secure.hex(4)}")
end

describe "alternatives plugin result key order" do
  it "serializes a check-mode install claim as changed-msg (real: changed, diff, msg)" do
    dir = unique_tmp("alternatives-order")
    FileUtils.mkdir_p(dir)
    link = File.join(dir, "kqalt")

    result = PluginSpecHelper.run("alternatives", {
      "name"                => "krikri-alt-order",
      "path"                => "/bin/sh",
      "link"                => link,
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal(["changed", "msg"])
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end
end
