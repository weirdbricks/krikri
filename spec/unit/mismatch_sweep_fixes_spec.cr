require "../spec_helper"
require "file_utils"
require "../../src/krikri/host"
require "../../src/krikri/inventory_parser"
require "../../src/krikri/template_action_plugin"

# Regression pins for the 2026-09 mismatch-sweep fixes (the six modules that
# showed DIVERGENT in the full podman-diff sweep after the engine-wide
# check-mode/_ansible_check_mode rewire, commit a2776a46):
#
# - cron: real cron.py's special_time vs time-fields mutual exclusion
#   ("You must specify time and date fields or special time.")
# - mount/replace: the executor-injected `_module_name` internal key must
#   not trip each plugin's own unsupported-params validator (it already
#   strips the shared AnsibleArgValidation INTERNAL list; these two carry
#   hand-rolled copies)
# - nsupdate: Python's own error wordings real wraps (binascii base64
#   errors, AnsibleModule's missing_required_lib for gssapi, dnspython's
#   OSError-shaped transport errors with UDP always reported as timeout)
# - template: real's two-line "Could not find or access ... on the Ansible
#   Controller" wording for a missing source
# - file: real's "Error, could not touch target: [Errno 2] ..." touch
#   wording, "src does not exist" hard-link setup check, and the chown
#   user-lookup failure surfacing WITHOUT plugin_manager's generic
#   "Plugin execution failed: " wrapper
#
# The live-engine side of each fix is confirmed by
# testing/podman-diff/cases/{cron,mount,nsupdate,replace,template,file}_edge_cases.yml.
describe "mismatch-sweep fixes (cron/mount/nsupdate/replace/template/file)" do
  it "cron rejects special_time combined with explicit time fields" do
    result = PluginSpecHelper.run("cron", {
      "name"         => "krikri-spec-c8",
      "minute"       => "5",
      "special_time" => "daily",
      "job"          => "/usr/bin/true",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("You must specify time and date fields or special time.")
  end

  it "cron accepts special_time alone (defaults are not explicit fields)" do
    result = PluginSpecHelper.run("cron", {
      "name"         => "krikri-spec-c4",
      "special_time" => "daily",
      "job"          => "/usr/bin/true",
      "cron_file"    => "/tmp/krikri-spec-crontab",
    })

    (result["failed"]?.try(&.as_bool) || false).should be_false
  end

  it "mount does not reject the executor's _module_name internal key" do
    result = PluginSpecHelper.run("mount", {
      "path"         => "/mnt/krikri-spec",
      "src"          => "tmpfs",
      "state"        => "mounted",
      "_module_name" => "ansible.posix.mount",
    })

    result["failed"].as_bool.should be_true
    # Missing fstype is the real first failure for this shape; the point
    # is that the failure is NOT the unsupported-params validator.
    result["msg"].as_s.should_not contain("Unsupported parameters")
  end

  it "replace does not reject the executor's _module_name internal key" do
    tmp = File.tempname("krikri-spec-replace")
    File.write(tmp, "beta=2\n")

    result = PluginSpecHelper.run("replace", {
      "path"         => tmp,
      "regexp"       => "^beta=2$",
      "replace"      => "beta=99",
      "_module_name" => "ansible.builtin.replace",
    })

    (result["failed"]?.try(&.as_bool) || false).should be_false
    result["changed"].as_bool.should be_true
    File.read(tmp).should eq("beta=99\n")
  ensure
    FileUtils.rm_f(tmp) if tmp
  end

  it "nsupdate wraps Python's binascii wording for a 1-mod-4 secret" do
    result = PluginSpecHelper.run("nsupdate", {
      "server"       => "127.0.0.1",
      "record"       => "a.example.org.",
      "zone"         => "example.org.",
      "key_name"     => "nsupdate",
      "key_secret"   => "!!!not-base64!!!",
      "_module_name" => "community.general.nsupdate",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
      "TSIG key error: Invalid base64-encoded string: number of data characters (9) " \
      "cannot be 1 more than a multiple of 4"
    )
  end

  it "nsupdate wraps AnsibleModule's missing_required_lib wording for gssapi" do
    result = PluginSpecHelper.run("nsupdate", {
      "server"        => "127.0.0.1",
      "record"        => "a.example.org.",
      "zone"          => "example.org.",
      "key_algorithm" => "gss-tsig",
      "_module_name"  => "community.general.nsupdate",
    })

    result["failed"].as_bool.should be_true
    msg = result["msg"].as_s
    msg.should start_with("Failed to import the required Python library (gssapi) on ")
    msg.should contain("This is required for gss-tsig keys. See https://github.com/pythongssapi/python-gssapi for more info.")
  end

  it "nsupdate surfaces a refused TCP connect as Python's OSError shape" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1",
      "port"   => "1",
      "record" => "a.example.org.",
      "zone"   => "example.org.",
      "value"  => "192.0.2.1",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("DNS server error: (ConnectionRefusedError): [Errno 111] Connection refused")
  end

  it "template reports a missing source with real's two-line wording" do
    # The not-found check lives in the controller-side action plugin (the
    # bin/plugins/template binary is the remote half that only sees
    # already-rendered content).
    plugin = Krikri::TemplateActionPlugin.new(
      {"src" => "/tmp/krikri-spec-does-not-exist.j2", "dest" => "/tmp/krikri-spec-template-out.txt"} of String => String,
      {} of String => JSON::Any,
      Krikri::Host.new("testhost")
    )
    result = plugin.execute

    result.success?.should be_false
    result.error_message.should eq(
      "Could not find or access '/tmp/krikri-spec-does-not-exist.j2' on the Ansible Controller.\n" \
      "If you are using a module and expect the file to exist on the remote, see the remote_src option"
    )
  end

  it "file reports the touch OS error like real's OSError str" do
    result = PluginSpecHelper.run("file", {
      "path"  => "/tmp/krikri-spec-nope/deep/file.txt",
      "state" => "touch",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
      "Error, could not touch target: [Errno 2] No such file or directory: b'/tmp/krikri-spec-nope/deep/file.txt'"
    )
  end

  it "file fails a hard link whose src does not exist with real's wording" do
    result = PluginSpecHelper.run("file", {
      "src"   => "/tmp/krikri-spec-no-such-source",
      "dest"  => "/tmp/krikri-spec-hard-link",
      "state" => "hard",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("src does not exist")
  end

  it "file surfaces the chown user-lookup failure without the generic wrapper" do
    path = File.tempname("krikri-spec-chown")
    File.touch(path)

    result = PluginSpecHelper.run("file", {
      "path"  => path,
      "state" => "touch",
      "owner" => "this_user_does_not_exist_zzz",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("chown failed: failed to look up user this_user_does_not_exist_zzz")
  ensure
    FileUtils.rm_f(path) if path
  end
end
