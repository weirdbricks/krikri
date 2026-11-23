require "../minitest_helper"
require "../../src/krikri/playbook_parser"
require "../../src/krikri/plugin_manager"

# Pins plugins/zypper.cr and plugins/zypper_repository.cr's ported surface
# (issue #1677, chkpnt.mailserver on Ubuntu) against real
# community.general: AnsibleModule's argument validation and the
# get_bin_path("zypper", required=True) probe both modules run before any
# package/repository work. zypper.py declares supports_check_mode=True, so
# real RUNS it under --check and the probe is what fatals the task;
# zypper_repository.py declares supports_check_mode=False, so real answers
# --check with basic.py's own skip. Before this, krikri's
# unavailable-module skip dropped both tasks, ran on into the role's setup
# files and reported a later task's failure with exit 4.
describe "zypper plugin argument validation" do
  it "fails without name" do
    result = PluginSpecHelper.run("zypper", {} of String => String)

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("missing required arguments: name")
  end

  it "treats pkg as name" do
    # The alias satisfies the required argument exactly like `name:`, so
    # the executable probe (not "missing required arguments") is the
    # failure on this zypper-less host.
    result = PluginSpecHelper.run("zypper", {"pkg" => "git"})

    result["failed"].as_bool.must_equal(true)
    str_starts_with?(result["msg"].as_s,
      "Failed to find required executable \"zypper\" in paths: ").must_equal(true)
  end

  it "fails an invalid state choice in declaration order" do
    result = PluginSpecHelper.run("zypper", {"name" => "git", "state" => "banana"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of state must be one of: absent, installed, latest, present, removed, dist-upgrade, got: banana")
  end

  it "fails an invalid type choice" do
    result = PluginSpecHelper.run("zypper", {"name" => "git", "type" => "banana"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of type must be one of: package, patch, pattern, product, srcpackage, application, got: banana")
  end

  it "rejects an unknown parameter with the invoked spelling" do
    result = PluginSpecHelper.run("zypper", {
      "name"         => "git",
      "banana"       => "x",
      "_module_name" => "community.general.zypper",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Unsupported parameters for (community.general.zypper) module: banana. Supported parameters include: " \
      "allow_vendor_change, auto_import_keys, clean_deps, disable_gpg_check, disable_recommends, extra_args, " \
      "extra_args_precommand, force, force_resolution, name, oldpackage, quiet, replacefiles, simple_errors, " \
      "skip_post_errors, state, type, update_cache (pkg, refresh).")
  end

  it "fails the task with get_bin_path's message under --check (issue #1677)" do
    # zypper.py declares supports_check_mode=True, so real does not skip
    # under --check: main() reaches get_cmd()'s probe and fatals there.
    result = PluginSpecHelper.run("zypper", {
      "name"                => "postfix,mailx,dovecot",
      "state"               => "present",
      "_ansible_check_mode" => "true",
    })

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    str_starts_with?(result["msg"].as_s,
      "Failed to find required executable \"zypper\" in paths: ").must_equal(true)
  end

  it "accepts the role's own task shape (present list name)" do
    result = PluginSpecHelper.run("zypper", {
      "name"  => "postfix,mailx,dovecot,rspamd,unbound,clamav,acl",
      "state" => "present",
    })

    result["failed"].as_bool.must_equal(true)
    str_starts_with?(result["msg"].as_s,
      "Failed to find required executable \"zypper\" in paths: ").must_equal(true)
  end

  it "fails a wrong-typed bool before the probe under --check (issue #1721)" do
    # The kpg chaos playbook hands the module a rendered list name plus
    # skip_post_errors: pnphwi. AnsibleModule validates every option's type
    # before main() runs, and --check does not change that, so real never
    # reaches get_cmd()'s probe here: the convert_bool message is the whole
    # failure both engines print for this task.
    result = PluginSpecHelper.run("zypper", {
      "name"                => "nwjbxv,iklusu",
      "skip_post_errors"    => "pnphwi",
      "auto_import_keys"    => "true",
      "disable_gpg_check"   => "true",
      "_ansible_check_mode" => "true",
    })

    result["failed"].as_bool.must_equal(true)
    # The frozenset tail's order is per-process in real; the members and
    # their quoting are not, so a change in either is a real divergence.
    result["msg"].as_s.must_equal(
      "argument 'skip_post_errors' is of type str and we were unable to convert to bool: " \
      "The value 'pnphwi' is not a valid boolean. " \
      "Valid booleans include: 'y', 'yes', 'on', '1', 'true', 't', 1, 'n', 'no', 'off', '0', 'false', 'f', 0")
  end
end

describe "zypper_repository plugin check mode and validation" do
  it "skips under --check with basic.py's own message (issue #1677)" do
    result = PluginSpecHelper.run("zypper_repository", {
      "name"                => "home_chkpnt_mailserver",
      "repo"                => "https://download.opensuse.org/repositories/home:/chkpnt:/mailserver/15.6/",
      "state"               => "present",
      "auto_import_keys"    => "true",
      "_ansible_check_mode" => "true",
      "_module_name"        => "community.general.zypper_repository",
    })

    # basic.py's skip result carries only skipped+msg; the controller
    # backfills changed/failed when it registers the task.
    result["skipped"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("remote module (community.general.zypper_repository) does not support check mode")
  end

  it "still fails argument validation first in check mode" do
    result = PluginSpecHelper.run("zypper_repository", {
      "repo"                => "https://example.com/repo",
      "name"                => "foo",
      "state"               => "banana",
      "_ansible_check_mode" => "true",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of state must be one of: present, absent, got: banana")
  end

  it "fails the task outside check mode when the zypper binary is missing" do
    result = PluginSpecHelper.run("zypper_repository", {
      "name"  => "home_chkpnt_mailserver",
      "repo"  => "https://download.opensuse.org/repositories/home:/chkpnt:/mailserver/15.6/",
      "state" => "present",
    })

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    str_starts_with?(result["msg"].as_s,
      "Failed to find required executable \"zypper\" in paths: ").must_equal(true)
  end

  it "fails priority before enabled, in the spec's declaration order" do
    result = PluginSpecHelper.run("zypper_repository", {
      "repo"     => "https://example.com/repo",
      "name"     => "foo",
      "priority" => "banana",
      "enabled"  => "banana",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("argument 'priority' is of type str and we were unable to convert to int: \"'banana'\" cannot be converted to an int")
  end
end

# Real resolves all four spellings onto community.general's modules (the
# bare ones through collection search, the builtin/legacy ones through
# ansible-core's own builtin runtime redirects) and RUNS them - a missing
# registry entry would drop the task as an unavailable module and skip it,
# which is the divergence #1677 records.
describe "zypper module resolution" do
  {% for spelling in ["zypper", "community.general.zypper", "ansible.builtin.zypper", "ansible.legacy.zypper"] %}
    it "resolves {{ spelling.id }}: to the zypper plugin, not an unavailable module" do
      playbook = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: play
          hosts: all
          tasks:
            - name: Install packages for mailserver
              {{ spelling.id }}:
                name:
                  - postfix
                state: present
        YAML
      task = playbook.plays[0].tasks[0]
      task.unavailable_module.must_be_nil
      Krikri::PluginManager.simple_plugin_name(task.module_name).must_equal("zypper")
    end
  {% end %}
end

describe "zypper_repository module resolution" do
  {% for spelling in ["zypper_repository", "community.general.zypper_repository", "ansible.builtin.zypper_repository", "ansible.legacy.zypper_repository"] %}
    it "resolves {{ spelling.id }}: to the zypper_repository plugin, not an unavailable module" do
      playbook = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: play
          hosts: all
          tasks:
            - name: Install repository home:chkpnt:mailserver
              {{ spelling.id }}:
                name: home_chkpnt_mailserver
                repo: https://example.com/repo
                state: present
        YAML
      task = playbook.plays[0].tasks[0]
      task.unavailable_module.must_be_nil
      Krikri::PluginManager.simple_plugin_name(task.module_name).must_equal("zypper_repository")
    end
  {% end %}
end
