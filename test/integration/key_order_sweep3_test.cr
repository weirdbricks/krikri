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
# The pins cover the keys krikri emits, in Ansible's relative order: Ansible's
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

# Whether a locale is actually present in the host's locale archive -
# the locale_gen unchanged path is only reachable when it already is.
private def locale_generated?(name : String) : Bool
  return false unless locale = Process.find_executable("locale")
  output = IO::Memory.new
  Process.run(locale, ["-a"], output: output, error: Process::Redirect::Close)
  output.to_s.each_line.any? { |line| normalize_locale(line.chomp).includes?(normalize_locale(name)) }
end

# `locale -a` renders the archive names the platform's own way
# ("en_US.utf8" where the module arg says "en_US.UTF-8"), so both sides
# are case-folded and dash-stripped before comparing.
private def normalize_locale(name : String) : String
  name.downcase.gsub("-", "")
end

describe "mount plugin result key order" do
  # state=absent against a throwaway fstab needs no real mount (the
  # present/remounted variants need a working mount(2), which the
  # unprivileged test host and rootless container both deny - those
  # were pinned from the live-verified absent shape, Ansible's single
  # exit_json(changed=changed, **args)).
  it "serializes an absent fstab-entry removal as Ansible's args order (verified live for state=absent)" do
    fstab = unique_tmp("mount-order-fstab")
    path = unique_tmp("mount-order-path")
    File.write(fstab, "tmpfs #{path} tmpfs defaults 0 0\n")

    result = PluginSpecHelper.run("mount", {
      "path"   => path,
      "src"    => "tmpfs",
      "fstype" => "tmpfs",
      "state"  => "absent",
      "fstab"  => fstab,
    })

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal([
      "changed", "name", "opts", "dump", "passno", "fstab", "boot", "backup_file", "src", "fstype",
      "deprecations", "_ansible_core_deprecations",
    ])

    result2 = PluginSpecHelper.run("mount", {
      "path"   => path,
      "src"    => "tmpfs",
      "fstype" => "tmpfs",
      "state"  => "absent",
      "fstab"  => fstab,
    })
    result2["changed"].as_bool.must_equal(false)
    result2.as_h.keys.must_equal([
      "changed", "name", "opts", "dump", "passno", "fstab", "boot", "backup_file", "src", "fstype",
      "deprecations", "_ansible_core_deprecations",
    ])
  ensure
    File.delete(fstab) if fstab && File.exists?(fstab)
  end
end

describe "apt plugin result key order" do
  # Unprivileged-testable apt paths only: the bare no-op ok (nothing to
  # remove) and the check-mode cache-update claim (needs python3-apt on
  # the host to pass Ansible's check-mode refusal). The install/remove/
  # upgrade/deb orders were live-verified identical in the podman
  # container.
  it "serializes the nothing-to-remove absent ok in Ansible's bare-changed-relative order" do
    result = PluginSpecHelper.run("apt", {"name" => "krikri-not-a-package-xyz", "state" => "absent"})

    result["changed"].as_bool.must_equal(false)
    # Real apt.py's remove() exits from INSIDE itself with a bare
    # exit_json(changed=False) when no package needs removing, so neither
    # msg nor the cache keys main() would otherwise assign onto the
    # retvals ever land on the result. Live-verified against
    # ansible-core 2.19.11: the registered result is {"changed": false}
    # plus the controller's own `failed` backfill.
    result.as_h.keys.must_equal(["changed"])
  end

  it "serializes a check-mode cache-update claim in Ansible's cache-keys order" do
    result = PluginSpecHelper.run("apt", {
      "update_cache"        => "yes",
      "_ansible_check_mode" => "true",
    })

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(true)
    # Real apt.py's check-mode cache pass claims updated_cache (and thus
    # cache_updated) unconditionally once the update was due.
    result["cache_updated"].as_bool.must_equal(true)
    # Real apt.py's cache-only exit carries no msg/stdout - just the
    # three keys (the controller appends failed).
    result.as_h.keys.must_equal(["changed", "cache_updated", "cache_update_time"])
  end
end

describe "locale_gen plugin result key order" do
  # The already-generated path needs no mutation (locale-gen itself is
  # root-only), so this pin is testable unprivileged; the changed and
  # check-mode orders were live-verified identical to it.
  it "serializes an already-generated locale as changed-name-ubuntu_mode-mechanism (real-verified)" do
    # This pin is the UNCHANGED path, which requires the locale to exist
    # already; a slim container image that never ran locale-gen cannot
    # reach it (and generating one needs root, which this spec
    # deliberately does not require).
    skip "en_US.UTF-8 is not generated on this host, so the unchanged path is unreachable" unless locale_generated?("en_US.UTF-8")
    result = PluginSpecHelper.run("locale_gen", {"name" => "en_US.UTF-8", "state" => "present"})

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal(["changed", "name", "ubuntu_mode", "mechanism"])
  end
end

describe "kernel_blacklist plugin result key order" do
  it "serializes a fresh present as changed-name-state-filename-lines-is_blacklisted (real-verified)" do
    file = unique_tmp("kernel-blacklist-order")
    File.delete(file) if File.exists?(file)

    result = PluginSpecHelper.run("kernel_blacklist", {"name" => "krikri_kbl", "blacklist_file" => file})

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal(["changed", "name", "state", "filename", "lines", "is_blacklisted"])
    result["lines"].as_a.map(&.as_s).must_equal(["blacklist krikri_kbl"])
  ensure
    File.delete(file) if file && File.exists?(file)
  end

  it "serializes an unchanged rerun in the same order" do
    file = unique_tmp("kernel-blacklist-order2")
    File.delete(file) if File.exists?(file)
    PluginSpecHelper.run("kernel_blacklist", {"name" => "krikri_kbl2", "blacklist_file" => file})

    result = PluginSpecHelper.run("kernel_blacklist", {"name" => "krikri_kbl2", "blacklist_file" => file})

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal(["changed", "name", "state", "filename", "lines", "is_blacklisted"])
  ensure
    File.delete(file) if file && File.exists?(file)
  end
end

describe "dpkg_divert plugin result key order" do
  it "serializes an unmodified absence as changed-diversion-commands-messages (real: changed, diversion, commands, messages, diff)" do
    skip "no dpkg-divert on this machine" unless File.exists?("/usr/bin/dpkg-divert") || File.exists?("/usr/sbin/dpkg-divert")

    result = PluginSpecHelper.run("dpkg_divert", {"path" => "/etc/hostname", "state" => "absent"})

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal(["changed", "diversion", "commands", "messages"])
  end
end

describe "dpkg_selections plugin result key order" do
  it "serializes an already-set selection as changed-before-after (real: changed, before, after)" do
    result = PluginSpecHelper.run("dpkg_selections", {"name" => "bash", "selection" => "install"})

    result["changed"].as_bool.must_equal(false)
    result["before"].as_s.must_equal("install")
    result.as_h.keys.must_equal(["changed", "before", "after"])
  end

  it "serializes a check-mode selection claim as changed-before-after" do
    result = PluginSpecHelper.run("dpkg_selections", {
      "name"                => "bash",
      "selection"           => "hold",
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal(["changed", "before", "after"])
  end
end

# Whether `debconf-show` already records `question` at `value`. The
# debconf specs' unchanged-path pin is only reachable where the host's
# debconf database is in that state to begin with (a slim container
# image never configured locales).
private def debconf_value_set?(pkg : String, question : String, value : String) : Bool
  return false unless show = Process.find_executable("debconf-show")
  output = IO::Memory.new
  Process.run(show, [pkg], output: output, error: Process::Redirect::Close)
  output.to_s.each_line.any? do |line|
    line.starts_with?("*") && line.includes?(question) && line.includes?(value)
  end
end

describe "debconf plugin result key order" do
  it "serializes an already-set question as changed-msg (real: changed, msg, current)" do
    skip "locales/default_environment_locale is not already en_US.UTF-8 in this host's debconf database" unless debconf_value_set?("locales", "locales/default_environment_locale", "en_US.UTF-8")
    result = PluginSpecHelper.run("debconf", {
      "name"     => "locales",
      "question" => "locales/default_environment_locale",
      "value"    => "en_US.UTF-8",
      "vtype"    => "string",
    })

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal(["changed", "msg"])
  end

  it "serializes a check-mode set as changed-msg (real: changed, msg, current, previous, diff)" do
    result = PluginSpecHelper.run("debconf", {
      "name"                => "locales",
      "question"            => "locales/default_environment_locale",
      "value"               => "fr_FR.UTF-8",
      "vtype"               => "string",
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal(["changed", "msg"])
  end
end

describe "capabilities plugin result key order" do
  # The unchanged exit needs only getcap (no root); the changed exits
  # need setcap (root-only on the host) and are covered by the
  # live-verified pins above.
  it "serializes an absent-nothing rerun as changed-state (real: changed, state)" do
    target = unique_tmp("capabilities-order-target")
    File.write(target, "#!/bin/sh\nexit 0\n")

    result = PluginSpecHelper.run("capabilities", {
      "path"       => target,
      "capability" => "cap_chown=ep",
      "state"      => "absent",
    })

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal(["changed", "state"])
  ensure
    File.delete(target) if target && File.exists?(target)
  end
end

describe "acl plugin result key order" do
  it "serializes a present-ACL success as changed-msg-acl (real: changed, msg, acl)" do
    # A filesystem that refuses setfacl (tmpfs/fuse mounts without acl
    # support, e.g. inside a job container) makes Ansible's acl task fail
    # identically, so this success-order pin needs a host that can
    # actually record an ACL.
    skip "no ACL support on this filesystem (setfacl is rejected)" unless PluginSpecHelper.setfacl_supported?
    target = unique_tmp("acl-order-target")
    File.write(target, "x\n")

    PluginSpecHelper.run("acl", {
      "path"        => target,
      "entity"      => "root",
      "etype"       => "user",
      "permissions" => "r",
      "state"       => "present",
    })
    result = PluginSpecHelper.run("acl", {
      "path"        => target,
      "entity"      => "root",
      "etype"       => "user",
      "permissions" => "r",
      "state"       => "present",
    })

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal(["changed", "msg", "acl"])
  ensure
    File.delete(target) if target && File.exists?(target)
  end
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
