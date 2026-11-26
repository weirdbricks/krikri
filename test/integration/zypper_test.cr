require "../minitest_helper"
require "../../src/krikri/playbook_parser"

# Pins plugins/zypper.cr's ported surface (issue #1850,
# billyrayvalentine.susefirewall on rocky): community.general.zypper's
# AnsibleModule argument validation and main()'s
# get_bin_path("zypper", required=True) probe. Real executes the module under
# --check (it declares supports_check_mode), so on a host without zypper that
# probe is the task's whole observable result - the engine used to answer
# with a graceful unavailable-module "skipping:" plus exit 4 instead.
describe "zypper plugin argument validation" do
  it "fails without name" do
    result = PluginSpecHelper.run("zypper", {} of String => String)

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("missing required arguments: name")
  end

  it "fails an invalid state choice" do
    result = PluginSpecHelper.run("zypper", {"name" => "SuSEfirewall2", "state" => "banana"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "value of state must be one of: absent, installed, latest, present, removed, dist-upgrade, got: banana")
  end

  it "fails an invalid type choice" do
    result = PluginSpecHelper.run("zypper", {"name" => "SuSEfirewall2", "type" => "banana"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "value of type must be one of: package, patch, pattern, product, srcpackage, application, got: banana")
  end

  it "rejects an unknown parameter with the spec-keys-then-aliases wording" do
    result = PluginSpecHelper.run("zypper", {"name" => "SuSEfirewall2", "bogus" => "1"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Unsupported parameters for (zypper) module: bogus. Supported parameters include: " \
      "allow_vendor_change, auto_import_keys, clean_deps, disable_gpg_check, disable_recommends, " \
      "extra_args, extra_args_precommand, force, force_resolution, name, oldpackage, quiet, " \
      "replacefiles, simple_errors, skip_post_errors, state, type, update_cache (pkg, refresh).")
  end

  it "fails a non-boolean quiet with parameters.py wording" do
    result = PluginSpecHelper.run("zypper", {"name" => "SuSEfirewall2", "quiet" => "banana"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include(
      "argument 'quiet' is of type str and we were unable to convert to bool: " \
      "The value 'banana' is not a valid boolean. Valid booleans include: ")
  end

  it "reports a bad refresh alias under its canonical update_cache name" do
    result = PluginSpecHelper.run("zypper", {"name" => "SuSEfirewall2", "refresh" => "banana"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("argument 'update_cache' is of type str")
  end

  it "fails the zypper executable probe like real (issue #1850)" do
    scratch = PluginSpecHelper.tmp_path("zypper-no-zypper")
    Dir.mkdir_p(scratch)
    %w[/sbin /usr/sbin /usr/local/sbin].each do |dir|
      skip "#{dir}/zypper exists on this host, zypper cannot be hidden" if File::Info.executable?(File.join(dir, "zypper"))
    end

    result = PluginSpecHelper.run("zypper",
      {"name" => "SuSEfirewall2", "state" => "present"},
      env: {"PATH" => "#{scratch}:/nonexistent-krikri-zypper-path"})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_match(/\AFailed to find required executable "zypper" in paths: /)
  end

  it "answers ok for an empty name without probing zypper" do
    # state=present with every name filtered out takes package_present's
    # early return before get_cmd, so real answers ok even with no zypper.
    result = PluginSpecHelper.run("zypper",
      {"name" => "", "state" => "present"},
      env: {"PATH" => "/nonexistent-krikri-zypper-path"})

    result["failed"]?.try(&.as_bool?).must_be_nil
    result["changed"].as_bool.must_equal(false)
  end

  it "probes for an empty absent name like real" do
    # package_absent calls get_installed_state before its own empty-list
    # return, so the probe still runs and fails without zypper.
    result = PluginSpecHelper.run("zypper",
      {"name" => "", "state" => "absent"},
      env: {"PATH" => "/nonexistent-krikri-zypper-path"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_match(/\AFailed to find required executable "zypper" in paths: /)
  end

  it "fails a specific-package dist-upgrade before the probe" do
    result = PluginSpecHelper.run("zypper",
      {"name" => "SuSEfirewall2", "state" => "dist-upgrade"},
      env: {"PATH" => "/nonexistent-krikri-zypper-path"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Can not dist-upgrade specific packages.")
  end

  it "fails removing patches before the probe" do
    result = PluginSpecHelper.run("zypper",
      {"name" => "SuSEfirewall2", "state" => "absent", "type" => "patch"},
      env: {"PATH" => "/nonexistent-krikri-zypper-path"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Can not remove patches.")
  end
end

describe "zypper resolution" do
  it "resolves the bare and builtin spellings to a real plugin" do
    playbook = Krikri::PlaybookParser.parse_string(
      "- name: issue 1850 repro play\n" \
      "  hosts: all\n" \
      "  tasks:\n" \
      "    - name: bare\n" \
      "      zypper:\n" \
      "        name: SuSEfirewall2\n" \
      "        state: present\n" \
      "    - name: builtin\n" \
      "      ansible.builtin.zypper:\n" \
      "        name: SuSEfirewall2\n" \
      "        state: present\n"
    )
    playbook.plays[0].tasks.each do |task|
      task.unavailable_module.must_equal(nil)
    end
    # parse-time validate() is the source of the "uses unimplemented
    # plugin" console warning - a ported module must not appear there.
    Krikri::PlaybookParser.validate(playbook).must_equal([] of String)
  end
end
