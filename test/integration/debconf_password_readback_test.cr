require "../minitest_helper"
require "file_utils"

# `vtype: password` read-back parity (issue #578): Ansible's debconf.py
# never takes a seeded password question's value from debconf-show's
# output - the `elif vtype == 'password'` branch (debconf.py:225) reads
# it back through `debconf-get-selections` (get_password_value,
# debconf.py:132), located via get_bin_path. That binary ships in
# debconf-utils, which a stock image lacks, so a warm re-run of a seeded
# password task fails there on every loop item while this engine used to
# report ok.
#
# The shims make the target's PATH a directory holding only the debconf
# binaries a test wants present, and the shims themselves use pure shell
# builtins: no /bin (whose merged-usr symlink to /usr/bin carries a real
# debconf-get-selections on dev boxes with debconf-utils installed), so
# the read-back's search list and outcome are fully controlled.

private def debconf_password_shim_dir(name : String, with_get_selections : Bool) : String
  dir = File.join(Dir.tempdir, "krikri-debconf-pw-#{name}-#{Random.rand(1_000_000)}")
  FileUtils.mkdir_p(dir)
  bins = ["debconf-show", "debconf-set-selections"]
  File.write(File.join(dir, "debconf-show"),
    "#!/bin/sh\nwhile IFS= read -r line; do printf '%s\\n' \"$line\"; done < \"$KRIKRI_DEBCONF_SHOW\"\n")
  File.write(File.join(dir, "debconf-set-selections"),
    "#!/bin/sh\nwhile IFS= read -r line; do printf '%s\\n' \"$line\" >> \"$KRIKRI_DEBCONF_LOG\"; done\n")
  if with_get_selections
    bins << "debconf-get-selections"
    File.write(File.join(dir, "debconf-get-selections"),
      "#!/bin/sh\nprintf 'call-get-selections\\n' >> \"$KRIKRI_DEBCONF_LOG\"\nprintf '%s' \"$KRIKRI_DEBCONF_DUMP\"\n")
  end
  bins.each { |bin| File.chmod(File.join(dir, bin), 0o755) }
  dir
end

private def debconf_password_env(dir : String, log : String, show_output : String, dump : String? = nil) : String
  # debconf-show prints one newline-terminated line per question; the shim's
  # `read` loop drops a final line with no newline, as the real tool never
  # emits one.
  File.write(File.join(dir, "show.txt"), "#{show_output}\n")
  env = {
    "PATH"                => dir,
    "KRIKRI_DEBCONF_SHOW" => File.join(dir, "show.txt"),
    "KRIKRI_DEBCONF_LOG"  => log,
  }
  env["KRIKRI_DEBCONF_DUMP"] = dump if dump
  env.to_json
end

describe "debconf plugin - vtype password read-back (get_password_value)" do
  it "fails like Ansible's get_bin_path when debconf-get-selections is missing" do
    dir = debconf_password_shim_dir("missing-getsel", with_get_selections: false)
    log = File.join(dir, "set-selections.log")
    result = PluginSpecHelper.run("debconf", {
      "name"         => "spec.pkg",
      "question"     => "spec.pkg/roothost",
      "vtype"        => "password",
      "value"        => "secret",
      "_environment" => debconf_password_env(dir, log, "spec.pkg/roothost: seeded"),
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.starts_with?(%(Task failed: Module failed: Failed to find required executable "debconf-get-selections" in paths: )).must_equal(true)
    result["msg"].as_s.must_include(dir)
    result["_ansible_error_detail"].as_s.starts_with?(%(Failed to find required executable "debconf-get-selections" in paths: )).must_equal(true)
    result["msg"].as_s.wont_include("secret")
    File.exists?(log).must_equal(false)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  # Ansible's read-back is part of the comparison, which check mode
  # performs too - only the set-selections call is skipped there.
  it "fails the same way in check mode" do
    dir = debconf_password_shim_dir("missing-getsel-check", with_get_selections: false)
    log = File.join(dir, "set-selections.log")
    result = PluginSpecHelper.run("debconf", {
      "name"                => "spec.pkg",
      "question"            => "spec.pkg/roothost",
      "vtype"               => "password",
      "value"               => "secret",
      "_ansible_check_mode" => "true",
      "_environment"        => debconf_password_env(dir, log, "spec.pkg/roothost: seeded"),
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.starts_with?(%(Task failed: Module failed: Failed to find required executable "debconf-get-selections" in paths: )).must_equal(true)
    result["_ansible_error_detail"].as_s.starts_with?(%(Failed to find required executable "debconf-get-selections" in paths: )).must_equal(true)
    File.exists?(log).must_equal(false)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "reports unchanged when the dumped value matches" do
    dir = debconf_password_shim_dir("dump-match", with_get_selections: true)
    log = File.join(dir, "set-selections.log")
    result = PluginSpecHelper.run("debconf", {
      "name"         => "spec.pkg",
      "question"     => "spec.pkg/roothost",
      "vtype"        => "password",
      "value"        => "secret",
      "_environment" => debconf_password_env(dir, log, "spec.pkg/roothost: seeded",
        dump: "spec.pkg\tspec.pkg/roothost\tpassword\tsecret\n"),
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("Value already set")
    File.read(log).must_equal("call-get-selections\n")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "re-applies when the dumped value differs" do
    dir = debconf_password_shim_dir("dump-differs", with_get_selections: true)
    log = File.join(dir, "set-selections.log")
    result = PluginSpecHelper.run("debconf", {
      "name"         => "spec.pkg",
      "question"     => "spec.pkg/roothost",
      "vtype"        => "password",
      "value"        => "secret",
      "_environment" => debconf_password_env(dir, log, "spec.pkg/roothost: seeded",
        dump: "spec.pkg\tspec.pkg/roothost\tpassword\toldsecret\n"),
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Value set")
    File.read(log).must_equal("call-get-selections\nspec.pkg spec.pkg/roothost password secret\n")
    File.read(log).wont_include("oldsecret")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "skips the read-back entirely when the question is not seeded" do
    dir = debconf_password_shim_dir("not-seeded", with_get_selections: true)
    log = File.join(dir, "set-selections.log")
    result = PluginSpecHelper.run("debconf", {
      "name"         => "spec.pkg",
      "question"     => "spec.pkg/roothost",
      "vtype"        => "password",
      "value"        => "secret",
      "_environment" => debconf_password_env(dir, log, "spec.pkg/unrelated: x"),
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Value set")
    File.read(log).must_equal("spec.pkg spec.pkg/roothost password secret\n")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  # get_password_value's `len(fields) <= 3` branch: a dump line without
  # the value field means an empty stored password.
  it "treats a dump line with no value field as an empty stored password" do
    dir = debconf_password_shim_dir("dump-short", with_get_selections: true)
    log = File.join(dir, "set-selections.log")
    result = PluginSpecHelper.run("debconf", {
      "name"         => "spec.pkg",
      "question"     => "spec.pkg/roothost",
      "vtype"        => "password",
      "value"        => "secret",
      "_environment" => debconf_password_env(dir, log, "spec.pkg/roothost: seeded",
        dump: "spec.pkg\tspec.pkg/roothost\tpassword\n"),
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    File.read(log).must_equal("call-get-selections\nspec.pkg spec.pkg/roothost password secret\n")
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
