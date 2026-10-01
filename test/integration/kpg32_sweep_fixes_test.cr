require "../minitest_helper"
require "json"
require "../../src/krikri/param_sentinels"
require "../../src/krikri/argspec_validator"
require "../../src/krikri/plugin_helpers/facts_gatherer"

# Regression tests for the six module groups a krikri-playbook-generator
# sweep (seed 32) flagged: expect, setup, subversion, apt_key, xml and
# deb822_repository. Every case below was reproduced locally against
# real ansible-playbook 2.19.11 (ansible_connection=local, no gather
# caching) before the fix, and the expected string is real's own.

# --- subversion -------------------------------------------------------------
#
# Real main() resolves `svn_path` with a bare
# `module.params['executable'] or module.get_bin_path('svn', True)` -
# it never stats or `--version`-probes an executable it was handed, and
# the dest-required check runs BEFORE any svn command is spawned. So a
# bad `executable:` loses to the dest message, and where nothing else
# fails first, the failure is basic.py's run_command OSError handler
# naming the operation real actually reached first - never a version
# probe.

describe "subversion plugin - executable resolution order (kpg32)" do
  it "reports the checkout command itself when executable: cannot be spawned" do
    missing = PluginSpecHelper.tmp_path("svn-kpg32-no-such-binary")

    result = PluginSpecHelper.run("subversion", {
      "dest"       => PluginSpecHelper.tmp_path("svn-kpg32-dest"),
      "executable" => missing,
      "repo"       => "rntmie",
      "revision"   => "drtlqr",
      "update"     => "true",
    })

    result["failed"].as_bool.must_equal(true)
    # ENOENT, and the command named is the CHECKOUT (the first svn call
    # real makes here), space-joined in real's own argv order - the
    # global options before the subcommand.
    result["rc"].as_i64.must_equal(2)
    result["cmd"].as_s.must_equal("#{missing} --non-interactive --no-auth-cache --trust-server-cert " \
                                  "checkout -r drtlqr rntmie #{PluginSpecHelper.tmp_path("svn-kpg32-dest")}")
    result["msg"].as_s.must_equal("Error executing command.")
    result["stderr"].as_s.must_equal("")
    result["stdout"].as_s.must_equal("")
  end

  it "names the export command when export: is the first operation" do
    missing = PluginSpecHelper.tmp_path("svn-kpg32-no-such-binary-export")
    dest = PluginSpecHelper.tmp_path("svn-kpg32-export-dest")

    result = PluginSpecHelper.run("subversion", {
      "dest"       => dest,
      "executable" => missing,
      "export"     => "true",
      "repo"       => "rntmie",
    })

    result["failed"].as_bool.must_equal(true)
    result["rc"].as_i64.must_equal(2)
    result["cmd"].as_s.must_equal("#{missing} --non-interactive --no-auth-cache --trust-server-cert " \
                                  "export -r HEAD rntmie #{dest}")
  end

  it "names the remote-revision info when checkout=no, update=no and export=no" do
    missing = PluginSpecHelper.tmp_path("svn-kpg32-no-such-binary-info")

    result = PluginSpecHelper.run("subversion", {
      "checkout"   => "no",
      "executable" => missing,
      "export"     => "no",
      "repo"       => "rntmie",
      "update"     => "no",
    })

    result["failed"].as_bool.must_equal(true)
    result["cmd"].as_s.must_equal("#{missing} --non-interactive --no-auth-cache --trust-server-cert info rntmie")
  end

  it "reports EACCES for an executable: that exists but is not executable" do
    plain = PluginSpecHelper.tmp_path("svn-kpg32-not-executable")
    File.write(plain, "")
    File.chmod(plain, 0o644)

    result = PluginSpecHelper.run("subversion", {
      "dest"       => PluginSpecHelper.tmp_path("svn-kpg32-noexec-dest"),
      "executable" => plain,
      "repo"       => "rntmie",
    })

    result["failed"].as_bool.must_equal(true)
    result["rc"].as_i64.must_equal(13)
  end

  it "requires dest before touching a missing executable:" do
    # main() fails on the missing dest first, so the executable is never
    # spawned and its own failure never gets reported.
    missing = PluginSpecHelper.tmp_path("svn-kpg32-no-such-binary-vs-dest")

    result = PluginSpecHelper.run("subversion", {
      "executable" => missing,
      "repo"       => "rntmie",
      "update"     => "true",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("the destination directory must be specified unless checkout=no, update=no, and export=no")
  end
end

# --- setup ------------------------------------------------------------------
#
# The FactsGatherer reads the RAW config JSON, so a `gather_timeout: 75`
# written unquoted in the playbook - which the parser marks as a
# non-string literal for the strings-only param wire - arrived as the
# literal string "nonstring:75" and failed the module with "argument
# 'gather_timeout' is of type str and we were unable to convert to
# int". Real converts the native int and carries on.

describe "setup gather_timeout as a native YAML int (kpg32)" do
  it "converts a marked non-string scalar back to the int the playbook wrote" do
    config = {
      "params" => {"gather_timeout" => "#{Krikri::NON_STRING_PARAM_PREFIX}75"},
    }.to_json

    result = JSON.parse(Krikri::FactsGatherer.run(JSON.parse(config)))

    expect(falsey?(result["failed"]?.try(&.as_bool))).must_equal(true)
  end

  it "still rejects a genuinely non-numeric gather_timeout with real's message" do
    # The marker's payload has to come back as the VALUE it stood for;
    # a string real cannot convert must still fail the module.
    result = JSON.parse(Krikri::FactsGatherer.run(JSON.parse({
      "params" => {"gather_timeout" => "abc"},
    }.to_json)))

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("argument 'gather_timeout' is of type str and we were unable to convert to int")
    expect(result["msg"].as_s.includes?("nonstring")).must_equal(false)
  end

  it "reports a bad gather_subset rather than the gather_timeout when both are given" do
    # Real's AnsibleModule validates gather_timeout (an int) at
    # construction and only then runs the module body, which is where
    # "Bad subset" comes from - so a VALID timeout must not shadow it.
    result = JSON.parse(Krikri::FactsGatherer.run(JSON.parse({
      "params" => {
        "gather_subset"  => ["pfuzhk"],
        "gather_timeout" => "#{Krikri::NON_STRING_PARAM_PREFIX}75",
      },
    }.to_json)))

    result["failed"].as_bool.must_equal(true)
    expect(str_starts_with?(result["msg"].as_s, "Bad subset 'pfuzhk' given to Ansible. gather_subset options allowed: all, "))
      .must_equal(true)
  end
end

# --- deb822_repository: choices on a type: list option ----------------------
#
# Real runs _validate_argument_values on the ALREADY type-converted
# parameters, and its per-member branch is guarded by
# `isinstance(parameters[param], list)` - which every `type: list`
# option satisfies by then, because check_type_list has already
# comma-split a scalar. So a scalar given to a list+choices option
# reports the PER-MEMBER wording, not the single-value one.

describe "deb822_repository types: validation wording (kpg32)" do
  it "reports a scalar given to a list+choices option in real's per-member wording" do
    vars = Hash(String, JSON::Any).new
    params = {
      "name"       => "whizio",
      "types"      => "pozmot",
      "uris"       => "http://example.com",
      "suites"     => "stable",
      "components" => "main",
    }

    result = Krikri::ArgspecValidator.validate("deb822_repository", "ansible.builtin.deb822_repository", params, vars)

    result.try(&.msg).must_equal(
      "value of types must be one or more of: deb, deb-src. Got no match for: pozmot")
  end

  it "keeps the per-member wording for an actual list, and comma-splits a scalar list" do
    vars = Hash(String, JSON::Any).new
    base = {
      "name"   => "whizio",
      "uris"   => "http://example.com",
      "suites" => "stable",
    }

    Krikri::ArgspecValidator.validate("deb822_repository", "ansible.builtin.deb822_repository",
      base.merge({"types" => "[\"rpm\"]"}), vars).try(&.msg).must_equal(
      "value of types must be one or more of: deb, deb-src. Got no match for: rpm")

    Krikri::ArgspecValidator.validate("deb822_repository", "ansible.builtin.deb822_repository",
      base.merge({"types" => "deb,nope"}), vars).try(&.msg).must_equal(
      "value of types must be one or more of: deb, deb-src. Got no match for: nope")
  end

  it "still accepts a valid scalar for the same option" do
    vars = Hash(String, JSON::Any).new

    result = Krikri::ArgspecValidator.validate("deb822_repository", "ansible.builtin.deb822_repository", {
      "name"       => "whizio",
      "types"      => "deb",
      "uris"       => "http://example.com",
      "suites"     => "stable",
      "components" => "main",
    }, vars)

    result.try(&.msg).must_be_nil
  end
end

# --- xml / expect: missing-Python-library gates ----------------------------
#
# Real's xml and expect import lxml/pexpect at MODULE level, so a target
# without them fails with missing_required_lib() before the module
# validates a parameter, reads a file or spawns anything. krikri
# implements both natively (krikri-xml, and the pty layer) and so has no
# such dependency - it used to report its own downstream outcome
# instead. A python3 that cannot import the library reproduces the
# target state; a real one (this dev machine has both) leaves the gate
# inert and behavior unchanged.

private def python_without_libs(name : String) : String
  dir = PluginSpecHelper.tmp_path("kpg32-pylibs-#{name}")
  Dir.mkdir_p(dir)
  shim = File.join(dir, "python3")
  # Reports its own executable the way real's missing_required_lib names
  # it, then fails any import with Python's own ImportError tail.
  # Pure shell (parameter expansion only): this directory is the whole
  # PATH for the duration, so an external helper like sed is not there.
  File.write(shim, <<-SHIM)
    #!/bin/sh
    case "$*" in
      *"sys.executable"*) echo "#{shim}" ;;
      *)
        echo "Traceback (most recent call last):" >&2
        echo "  File <string>, line 1, in <module>" >&2
        echo "ModuleNotFoundError: No module named '${2#import }'" >&2
        exit 1 ;;
    esac
  SHIM
  File.chmod(shim, 0o755)
  dir
end

describe "expect plugin - pexpect library gate (kpg32)" do
  it "fails with missing_required_lib before the command is even looked up" do
    dir = python_without_libs("pexpect")

    result = PluginSpecHelper.run("expect", {
      "command"   => "jzosqw",
      "creates"   => "/tmp/krikri-no-such-creates",
      "responses" => "{}",
    }, {} of String => String, "localhost", env: {"PATH" => dir})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    msg = result["msg"].as_s
    expect(str_starts_with?(msg, "Failed to import the required Python library (pexpect) on ")).must_equal(true)
    expect(msg.includes?("'s Python ")).must_equal(true)
    expect(msg.ends_with?("please consult the documentation on ansible_python_interpreter")).must_equal(true)
    # The command is NOT named: real never reaches the spawn.
    expect(msg.includes?("jzosqw")).must_equal(false)
  end

  it "wins over the creates:/removes: skip, which real also never reaches" do
    dir = python_without_libs("pexpect-skip")
    dest = PluginSpecHelper.tmp_path("kpg32-expect-creates")

    result = PluginSpecHelper.run("expect", {
      "command"   => "true",
      "creates"   => dest,
      "responses" => "{}",
    }, {} of String => String, "localhost", env: {"PATH" => dir})

    result["failed"].as_bool.must_equal(true)
    expect(str_starts_with?(result["msg"].as_s, "Failed to import the required Python library (pexpect) on "))
      .must_equal(true)
  end

  it "carries the ImportError reason as [ERROR]-only detail, never in the result msg" do
    dir = python_without_libs("pexpect-detail")

    result = PluginSpecHelper.run("expect", {
      "command"   => "jzosqw",
      "responses" => "{}",
    }, {} of String => String, "localhost", env: {"PATH" => dir})

    result["failed"].as_bool.must_equal(true)
    expect(result["msg"].as_s.includes?("No module named")).must_equal(false)
    result["_ansible_error_detail"].as_s.ends_with?(": No module named 'pexpect'").must_equal(true)
  end

  it "is inert when the target's python can import pexpect" do
    # This dev machine has real pexpect, so the plugin must behave
    # exactly as it did before the gate existed.
    result = PluginSpecHelper.run("expect", {
      "command"   => "krikri-no-such-command-xyz",
      "responses" => "{}",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("The command was not found or was not executable: krikri-no-such-command-xyz.")
  end
end

describe "xml plugin - lxml library gate (kpg32)" do
  it "fails with missing_required_lib before the source is read or parsed" do
    dir = python_without_libs("lxml")
    source = PluginSpecHelper.tmp_path("kpg32-lxml-source.xml")
    File.write(source, "<a><b/></a>")

    result = PluginSpecHelper.run("xml", {
      "path"  => source,
      "xpath" => "/a",
    }, {} of String => String, "localhost", env: {"PATH" => dir})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    msg = result["msg"].as_s
    expect(str_starts_with?(msg, "Failed to import the required Python library (lxml) on ")).must_equal(true)
    expect(msg.ends_with?("please consult the documentation on ansible_python_interpreter")).must_equal(true)
  end

  it "wins over the missing-source message, which real also never reaches" do
    dir = python_without_libs("lxml-missing-source")

    result = PluginSpecHelper.run("xml", {
      "path"  => "/tmp/krikri-no-such-source.xml",
      "xpath" => "/a",
    }, {} of String => String, "localhost", env: {"PATH" => dir})

    result["failed"].as_bool.must_equal(true)
    expect(result["msg"].as_s.includes?("does not exist")).must_equal(false)
    expect(str_starts_with?(result["msg"].as_s, "Failed to import the required Python library (lxml) on "))
      .must_equal(true)
  end

  it "is inert when the target's python can import lxml" do
    source = PluginSpecHelper.tmp_path("kpg32-lxml-present.xml")
    File.write(source, "<a><b/></a>")

    result = PluginSpecHelper.run("xml", {
      "path"  => source,
      "xpath" => "/a",
    })

    expect(falsey?(result["failed"]?.try(&.as_bool))).must_equal(true)
  end
end
