require "../minitest_helper"
require "file_utils"
require "../../src/krikri/argspec_validator"

private def scratch_dir : String
  dir = PluginSpecHelper.tmp_path("error-path-parity")
  FileUtils.mkdir_p(dir)
  dir
end

# Shorthand for the validator's failure record, unwrapped with `as`
# rather than `not_nil!` so a wrong expectation (the validator returned
# nil) fails naming the value it actually produced.
alias Failure = Krikri::ArgspecValidator::Failure

# Error-path shapes found by the differential fuzzer (krikri-playbook-generator)
# vs real ansible-core 2.19.11: every expectation below was checked against
# real ansible's own module source / a live run, not guessed.
describe "error-path parity with real ansible (fuzzer findings)" do
  it "replace/blockinfile/lineinfile report a missing file with ' !' and rc 257" do
    missing = File.join(scratch_dir, "no-such-file-zzz")

    replace = PluginSpecHelper.run("replace", {"path" => missing, "regexp" => "a", "replace" => "b"})
    replace["failed"].as_bool.must_equal(true)
    replace["msg"].as_s.must_equal("Path #{missing} does not exist !")
    replace["rc"].as_i.must_equal(257)

    block = PluginSpecHelper.run("blockinfile", {"path" => missing, "block" => "x"})
    block["msg"].as_s.must_equal("Path #{missing} does not exist !")
    block["rc"].as_i.must_equal(257)

    line = PluginSpecHelper.run("lineinfile", {"path" => missing, "line" => "x"})
    line["msg"].as_s.must_equal("Destination #{missing} does not exist !")
    line["rc"].as_i.must_equal(257)
  end

  it "find failure dumps carry the offending age/size value" do
    age = PluginSpecHelper.run("find", {"paths" => scratch_dir, "age" => "banana"})
    age["msg"].as_s.must_equal("failed to process age")
    age["age"].as_s.must_equal("banana")

    size = PluginSpecHelper.run("find", {"paths" => scratch_dir, "size" => "banana"})
    size["msg"].as_s.must_equal("failed to process size")
    size["size"].as_s.must_equal("banana")
  end

  it "find turns a non-directory search path into real's module warning" do
    file = File.join(scratch_dir, "a-file")
    File.write(file, "x")
    result = PluginSpecHelper.run("find", {"paths" => file})
    result["skipped_paths"][file].as_s.must_equal("'#{file}' is not a directory")
    result["warnings"].as_a.map(&.as_s).must_equal(
      ["Skipped '#{file}' path due to this access issue: '#{file}' is not a directory\n"])
  end

  it "hostname use: macosx fails like get_bin_path('scutil') does on Linux" do
    result = PluginSpecHelper.run("hostname", {"name" => "example", "use" => "macosx"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_match(/\AFailed to find required executable "scutil" in paths: /)
  end

  it "assemble with remote_src: false and a non-directory src is an action-level failure" do
    file = File.join(scratch_dir, "src-file")
    File.write(file, "x")
    result = PluginSpecHelper.run("assemble", {"src" => file, "dest" => File.join(scratch_dir, "out"), "remote_src" => "false"})
    result["msg"].as_s.must_equal("Source (#{file}) is not a directory")
    result["_ansible_action_level"].as_bool.must_equal(true)

    # default remote_src: the MODULE reports it (no action-level flag)
    module_level = PluginSpecHelper.run("assemble", {"src" => file, "dest" => File.join(scratch_dir, "out")})
    module_level["msg"].as_s.must_equal("Source (#{file}) is not a directory")
    module_level["_ansible_action_level"]?.must_be_nil
  end

  it "command: a bad chdir wins over a creates: that would skip the task" do
    missing = File.join(scratch_dir, "no-such-dir")
    result = PluginSpecHelper.run("command", {"cmd" => "true", "chdir" => missing, "creates" => "/"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Unable to change directory before execution.")
  end

  it "fetch: a missing src fails with changed+msg only and the module text for the [ERROR] block" do
    missing = File.join(scratch_dir, "no-such-src")
    result = PluginSpecHelper.run("fetch", {"src" => missing, "dest" => File.join(scratch_dir, "d") + "/"})
    result["msg"].as_s.must_equal("the remote file does not exist, not transferring, ignored")
    result["file"]?.must_be_nil
    result["_ansible_error_detail"].as_s.must_equal(
      "File not found: #{missing}: [Errno 2] No such file or directory: '#{missing}'")
  end

  it "lineinfile: state=present without line uses real's wording" do
    file = File.join(scratch_dir, "li-file")
    File.write(file, "x\n")
    result = PluginSpecHelper.run("lineinfile", {"path" => file, "state" => "present"})
    result["msg"].as_s.must_equal("line is required with state=present")
  end

  it "file: recurse on a non-directory carries add_path_info like real's fail_json(path=...)" do
    file = File.join(scratch_dir, "recurse-file")
    File.write(file, "x\n")
    result = PluginSpecHelper.run("file", {"path" => file, "recurse" => "true"})
    result["msg"].as_s.must_equal("recurse option requires state to be 'directory'")
    result["path"].as_s.must_equal(file)
    result["state"].as_s.must_equal("file")
    result["size"].as_i.must_equal(2)
  end

  it "find: an unknown contains: encoding abandons the search path (skipped_paths + warning)" do
    dir = File.join(scratch_dir, "enc-dir")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "f.txt"), "tree\n")
    result = PluginSpecHelper.run("find", {"paths" => dir, "contains" => "tree", "encoding" => "podiis"})
    result["skipped_paths"][dir].as_s.must_equal("unknown encoding: podiis")
    result["warnings"].as_a.map(&.as_s).must_equal(
      ["Skipped '#{dir}' path due to this access issue: unknown encoding: podiis\n"])
  end

  it "template/copy required-argument checks are action-level and come first" do
    vars = Hash(String, JSON::Any).new
    template = Krikri::ArgspecValidator.validate("template", "ansible.builtin.template", {"src" => "x"}, vars)
    template.as(Failure).msg.must_equal("src and dest are required")
    template.as(Failure).action_level?.must_equal(true)

    copy_dest = Krikri::ArgspecValidator.validate("copy", "ansible.builtin.copy", {"src" => "x"}, vars)
    copy_dest.as(Failure).msg.must_equal("dest is required")
    copy_src = Krikri::ArgspecValidator.validate("copy", "ansible.builtin.copy", {"dest" => "x"}, vars)
    copy_src.as(Failure).msg.must_equal("src (or content) is required")
  end

  it "cron: cron_file without user and the cron_file basename warning follow cron.py" do
    result = PluginSpecHelper.run("cron", {"name" => "x", "job" => "true", "cron_file" => File.join(scratch_dir, "bad.name")})
    result["msg"].as_s.must_equal("To use cron_file=... parameter you must specify user=... as well")
    result["warnings"].as_a.map(&.as_s).must_equal(
      [%(Filename portion of cron_file ("bad.name") should consist solely of upper- and lower-case letters, digits, underscores, and hyphens)])
  end

  it "wait_for: runtime checks fail with real's wording and elapsed=0" do
    both = PluginSpecHelper.run("wait_for", {"port" => "80", "path" => "/tmp"})
    both["msg"].as_s.must_equal("port and path parameter can not both be passed to wait_for")
    both["elapsed"].as_i.must_equal(0)

    stopped = PluginSpecHelper.run("wait_for", {"path" => "/tmp", "state" => "stopped"})
    stopped["msg"].as_s.must_equal("state=stopped should only be used for checking a port in the wait_for module")

    bogus = PluginSpecHelper.run("wait_for", {"port" => "1", "active_connection_states" => "ESTABLISHED,BOGUS"})
    bogus["msg"].as_s.must_equal("unknown active_connection_state (BOGUS) defined")
  end

  it "unarchive: a dest that is not a directory is an action-level failure" do
    src = File.join(scratch_dir, "a.tar")
    File.write(src, "x")
    result = PluginSpecHelper.run("unarchive", {"src" => src, "dest" => File.join(scratch_dir, "no-such-dir"), "remote_src" => "true"})
    result["msg"].as_s.must_match(/\Adest '.*no-such-dir' must be an existing dir\z/)
    result["_ansible_action_level"].as_bool.must_equal(true)
  end

  it "validator: systemd required_by keeps spec order; service validates its own spec without a systemd fact" do
    vars = Hash(String, JSON::Any).new
    systemd = Krikri::ArgspecValidator.validate("systemd", "ansible.builtin.systemd", {"state" => "started", "enabled" => "true"}, vars)
    systemd.as(Failure).msg.must_equal("missing parameter(s) required by 'state': name")

    service_vars = {"ansible_service_mgr" => JSON::Any.new("service")}
    service = Krikri::ArgspecValidator.validate("service", "ansible.builtin.service", {"zz" => "1", "name" => "x", "state" => "started"}, service_vars)
    service.as(Failure).msg.must_equal(
      "Unsupported parameters for (ansible.legacy.service) module: zz. " \
      "Supported parameters include: arguments, enabled, name, pattern, runlevel, sleep, state (args).")
    Krikri::ArgspecValidator.validate("service", "ansible.builtin.service", {"use" => "auto", "name" => "x", "state" => "started"}, service_vars).must_be_nil
  end

  it "cron: state=present without job uses cron.py's wording" do
    result = PluginSpecHelper.run("cron", {"name" => "x", "user" => "root", "cron_file" => File.join(scratch_dir, "kpgcron")})
    result["msg"].as_s.must_equal("You must specify 'job' to install a new cron job or variable")
  end

  it "unarchive: the action plugin's own checks come first, in order, and the module prints as ansible.legacy" do
    vars = Hash(String, JSON::Any).new
    both = Krikri::ArgspecValidator.validate("unarchive", "ansible.builtin.unarchive",
      {"src" => "a.tar", "dest" => "/tmp", "copy" => "false", "remote_src" => "true"}, vars)
    both.as(Failure).msg.must_equal("parameters are mutually exclusive: ('copy', 'remote_src')")
    both.as(Failure).action_level?.must_equal(true)
    Krikri::ArgspecValidator.failure_kind?("ansible.builtin.unarchive", both.as(Failure).msg).must_equal(:action)

    missing = Krikri::ArgspecValidator.validate("unarchive", "ansible.builtin.unarchive", {"dest" => "/tmp"}, vars)
    missing.as(Failure).msg.must_equal("src (or content) and dest are required")

    typo = Krikri::ArgspecValidator.validate("unarchive", "ansible.builtin.unarchive",
      {"src" => "a.tar", "dest" => "/tmp", "remote_src" => "true", "zz" => "1"}, vars)
    typo.as(Failure).msg.must_match(/\AUnsupported parameters for \(ansible\.legacy\.unarchive\) module: zz\./)
  end

  it "wait_for: a successful result echoes state/port/search_regex and the path's add_path_info fields" do
    file = File.join(scratch_dir, "wf-file")
    File.write(file, "hello\n")
    result = PluginSpecHelper.run("wait_for", {"path" => file, "timeout" => "2", "search_regex" => "hello"})
    result["port"].raw.must_be_nil
    result["search_regex"].as_s.must_equal("hello")
    result["state"].as_s.must_equal("file") # add_path_info overrides the wait state
    result["size"].as_i.must_equal(6)
    result["path"].as_s.must_equal(file)
  end

  it "assert: unsupported parameters name the action plugin's module path like real" do
    vars = Hash(String, JSON::Any).new
    failure = Krikri::ArgspecValidator.validate("ansible.builtin.assert", "ansible.builtin.assert", {"that" => "true", "that_bogus" => "1"}, vars)
    failure.as(Failure).msg.must_equal(
      "Unsupported parameters for (ansible_collections.ansible.builtin.plugins.action.assert) module: that_bogus. " \
      "Supported parameters include: fail_msg, quiet, success_msg, that (msg).")
  end

  it "package: an unknown use: is an action-level failure; the delegate module validates the rest" do
    vars = Hash(String, JSON::Any).new
    use = Krikri::ArgspecValidator.validate("ansible.builtin.package", "ansible.builtin.package", {"name" => "x", "use" => "dqjdfl"}, vars)
    use.as(Failure).msg.must_equal(%(Could not find a matching action for the "dqjdfl" package manager.))
    use.as(Failure).action_level?.must_equal(true)

    if File.exists?("/usr/bin/apt-get")
      state = Krikri::ArgspecValidator.validate("ansible.builtin.package", "ansible.builtin.package", {"name" => "x", "state" => "bogus"}, vars)
      state.as(Failure).msg.must_equal("value of state must be one of: absent, build-dep, fixed, latest, present, got: bogus")
    end
  end

  it "get_url/uri: checksum format, scheme-less URLs and real's failure keys" do
    dest = File.join(scratch_dir, "gu-dest")
    checksum = PluginSpecHelper.run("get_url", {"url" => "http://example.invalid/x", "dest" => dest, "checksum" => "nocolon"})
    checksum["msg"].as_s.must_equal("The checksum parameter has to be in format <algorithm>:<checksum>")
    checksum["checksum_dest"].raw.must_be_nil
    checksum["url"].as_s.must_equal("http://example.invalid/x")

    scheme = PluginSpecHelper.run("get_url", {"url" => "wezwmn", "dest" => dest})
    scheme["msg"].as_s.must_equal("unknown url type: 'wezwmn'")
    scheme["status"].as_i.must_equal(-1)
    scheme["dest"]?.must_be_nil

    uri = PluginSpecHelper.run("uri", {"url" => "wezwmn"})
    uri["msg"].as_s.must_equal("Status code was -1 and not [200]: Connection failure: [Errno 2] No such file or directory")
    uri["content"]?.must_be_nil
  end

  it "rpm_key/subversion/git: real's missing-executable and details keys" do
    if Process.find_executable("rpm").nil?
      PluginSpecHelper.run("rpm_key", {"key" => "x"})["msg"].as_s.must_match(/\AFailed to find required executable "rpm" in paths: /)
    end
    if Process.find_executable("svn").nil?
      PluginSpecHelper.run("subversion", {"repo" => "svn://x", "dest" => File.join(scratch_dir, "svn")})["msg"].as_s.must_match(/\AFailed to find required executable "svn" in paths: /)
    end
    git = PluginSpecHelper.run("git", {"repo" => "x", "dest" => File.join(scratch_dir, "g"), "umask" => "zz9"})
    git["msg"].as_s.must_equal("umask must be an octal integer")
    git["details"].as_s.must_equal("invalid literal for int() with base 8: 'zz9'")
  end
end
