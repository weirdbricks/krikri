require "../minitest_helper"
require "file_utils"
require "../../src/krikri/param_sentinels"

# Parameter-coverage pass for `debconf:`'s required_together contract:
# real ansible-core's debconf.py declares
# `required_together=(['question', 'vtype', 'value'],)`, enforced by
# AnsibleModule with validation.py's exact message "parameters are
# required together: question, vtype, value" - any one (or two) of the
# three without the rest fails the task. This engine previously only
# checked the question-side half, so `vtype:`/`value:` alone silently
# "succeeded" as "No question given, nothing to set".
#
# The debconf binaries are PATH-shimmed via `environment:` so nothing
# here touches the real debconf database.

private def debconf_shim_dir(name : String) : {String, String}
  dir = File.join(Dir.tempdir, "krikri-debconf-#{name}-#{Random.rand(1_000_000)}")
  FileUtils.mkdir_p(dir)
  log = File.join(dir, "set-selections.log")
  File.write(File.join(dir, "debconf-show"), "#!/bin/sh\ncat \"$KRIKRI_DEBCONF_SHOW\"\n")
  File.write(File.join(dir, "debconf-set-selections"), "#!/bin/sh\ncat >> \"$KRIKRI_DEBCONF_LOG\"\n")
  File.write(File.join(dir, "debconf-get-selections"), "#!/bin/sh\ntrue\n")
  {"debconf-show", "debconf-set-selections", "debconf-get-selections"}.each do |bin|
    File.chmod(File.join(dir, bin), 0o755)
  end
  File.write(File.join(dir, "current.txt"), "")
  {dir, log}
end

private def debconf_env(dir : String, log : String, show_output : String) : String
  File.write(File.join(dir, "show.txt"), show_output)
  {
    "PATH"                => "#{dir}:/usr/bin:/bin",
    "KRIKRI_DEBCONF_SHOW" => File.join(dir, "show.txt"),
    "KRIKRI_DEBCONF_LOG"  => log,
  }.to_json
end

describe "debconf plugin - required_together (question/vtype/value)" do
  it "fails when only vtype is given (real Ansible's required_together violation)" do
    dir, log = debconf_shim_dir("vtype-alone")
    result = PluginSpecHelper.run("debconf", {
      "name"         => "spec.pkg",
      "vtype"        => "boolean",
      "_environment" => debconf_env(dir, log, ""),
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("parameters are required together: question, vtype, value")
    File.exists?(log).must_equal(false)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "fails when question and value are given but vtype is missing" do
    dir, log = debconf_shim_dir("missing-vtype")
    result = PluginSpecHelper.run("debconf", {
      "name"         => "spec.pkg",
      "question"     => "spec.pkg/keyboard-layout",
      "answer"       => "us",
      "_environment" => debconf_env(dir, log, ""),
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("parameters are required together: question, vtype, value")
    File.exists?(log).must_equal(false)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "fails when setting and vtype are given (aliases count too) but the value is missing" do
    dir, log = debconf_shim_dir("alias-partial")
    result = PluginSpecHelper.run("debconf", {
      "name"         => "spec.pkg",
      "setting"      => "spec.pkg/keyboard-layout",
      "vtype"        => "string",
      "_environment" => debconf_env(dir, log, ""),
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("parameters are required together: question, vtype, value")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "rejects an invalid vtype choice before any debconf call (real Ansible's choices check)" do
    dir, log = debconf_shim_dir("bad-vtype")
    result = PluginSpecHelper.run("debconf", {
      "name"         => "spec.pkg",
      "question"     => "spec.pkg/keyboard-layout",
      "vtype"        => "krikri_vtype",
      "value"        => "us",
      "_environment" => debconf_env(dir, log, ""),
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of vtype must be one of: boolean, error, multiselect, note, password, seen, select, string, text, title, got: krikri_vtype")
    File.exists?(log).must_equal(false)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "accepts all three together and applies the selection" do
    dir, log = debconf_shim_dir("all-three")
    result = PluginSpecHelper.run("debconf", {
      "name"         => "spec.pkg",
      "question"     => "spec.pkg/keyboard-layout",
      "vtype"        => "string",
      "value"        => "de",
      "_environment" => debconf_env(dir, log, "spec.pkg/keyboard-layout: us"),
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Value set")
    File.read(log).strip.must_equal("spec.pkg spec.pkg/keyboard-layout string de")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "accepts all three together and reports no change when the value already matches" do
    dir, log = debconf_shim_dir("all-three-match")
    result = PluginSpecHelper.run("debconf", {
      "name"         => "spec.pkg",
      "setting"      => "spec.pkg/keyboard-layout",
      "vtype"        => "string",
      "answer"       => "us",
      "_environment" => debconf_env(dir, log, "spec.pkg/keyboard-layout: us"),
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("Value already set")
    File.exists?(log).must_equal(false)
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end

# Non-string `value:` literals: real's debconf.py builds the
# debconf-set-selections line with a Python `' '.join([pkg, question,
# vtype, value])` (debconf.py:179), and `value:` is the module's only
# `type: raw` option - so an int/bool/float literal reaches that join as
# itself and kills the module with an uncaught TypeError, "Task failed:
# Module failed: sequence item 3: expected str instance, int found"
# (live-verified vs ansible-core 2.19.11 for every type below). Only
# name/question/vtype can be written as literals without crashing: their
# `type: str` spec converts them to text first. The join is reached only
# once the value is known to differ and the run is not a --check one, so
# both of those report changed instead.
#
# The marker values here are what the playbook parser puts on the wire
# for those literals (NON_STRING_PARAM_PREFIX / NON_STRING_MEMBER_PREFIX,
# see src/krikri/param_sentinels.cr); the end-to-end rendering of the
# same crash is covered in non_string_literal_params_test.cr.
describe "debconf plugin - non-string value: literals (real's set_selection join crash)" do
  it "crashes on an int value like real's uncaught ' '.join TypeError" do
    dir, log = debconf_shim_dir("int-value")
    result = PluginSpecHelper.run("debconf", {
      "name"         => "spec.pkg",
      "question"     => "16",
      "value"        => Krikri::NON_STRING_PARAM_PREFIX + "76",
      "vtype"        => "text",
      "_environment" => debconf_env(dir, log, ""),
    })

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("Task failed: Module failed: sequence item 3: expected str instance, int found")
    result["_ansible_error_detail"].as_s.must_equal("sequence item 3: expected str instance, int found")
    File.exists?(log).must_equal(false)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "crashes on a bool value with real's own plain type name" do
    dir, log = debconf_shim_dir("bool-value")
    result = PluginSpecHelper.run("debconf", {
      "name"         => "spec.pkg",
      "question"     => "spec.pkg/boolean",
      "value"        => Krikri::NON_STRING_PARAM_PREFIX + "true",
      "vtype"        => "text",
      "_environment" => debconf_env(dir, log, ""),
    })

    result["msg"].as_s.must_equal("Task failed: Module failed: sequence item 3: expected str instance, bool found")
    File.exists?(log).must_equal(false)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "crashes on a float value with real's own plain type name" do
    dir, log = debconf_shim_dir("float-value")
    result = PluginSpecHelper.run("debconf", {
      "name"         => "spec.pkg",
      "question"     => "spec.pkg/ratio",
      "value"        => Krikri::NON_STRING_PARAM_PREFIX + "1.5",
      "vtype"        => "text",
      "_environment" => debconf_env(dir, log, ""),
    })

    result["msg"].as_s.must_equal("Task failed: Module failed: sequence item 3: expected str instance, float found")
    File.exists?(log).must_equal(false)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  # The crash looks the value up under the alias the task actually used
  # (value:/answer: are the same option) - the marked literal rides on
  # whichever key was written.
  it "crashes on an int answer: exactly like value:" do
    dir, log = debconf_shim_dir("int-answer")
    result = PluginSpecHelper.run("debconf", {
      "name"         => "spec.pkg",
      "setting"      => "spec.pkg/keyboard-layout",
      "answer"       => Krikri::NON_STRING_PARAM_PREFIX + "76",
      "vtype"        => "text",
      "_environment" => debconf_env(dir, log, ""),
    })

    result["msg"].as_s.must_equal("Task failed: Module failed: sequence item 3: expected str instance, int found")
    File.exists?(log).must_equal(false)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  # real's `if vtype == 'boolean': value = to_text(value).lower()`
  # (debconf.py:214) runs BEFORE the comparison, so any type becomes text
  # and the join only ever sees a string there - an int value seeds "76"
  # instead of crashing.
  it "seeds a non-string value as text under vtype boolean, like real's to_text()" do
    dir, log = debconf_shim_dir("int-value-boolean")
    result = PluginSpecHelper.run("debconf", {
      "name"         => "spec.pkg",
      "question"     => "spec.pkg/boolean",
      "value"        => Krikri::NON_STRING_PARAM_PREFIX + "76",
      "vtype"        => "boolean",
      "_environment" => debconf_env(dir, log, ""),
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    File.read(log).strip.must_equal("spec.pkg spec.pkg/boolean boolean 76")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  # name/question/vtype are `type: str`, so real's own spec converts an
  # int literal to its text (check_type_str's allow_conversion) and the
  # join never sees a non-string there - the question is seeded as "16".
  it "stringifies an int question through real's own type: str conversion" do
    dir, log = debconf_shim_dir("int-question")
    result = PluginSpecHelper.run("debconf", {
      "name"         => Krikri::NON_STRING_PARAM_PREFIX + "7",
      "question"     => Krikri::NON_STRING_PARAM_PREFIX + "16",
      "value"        => "us",
      "vtype"        => "text",
      "_environment" => debconf_env(dir, log, ""),
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    File.read(log).strip.must_equal("7 16 text us")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  # A literal `value:` (or a template that natively resolved to None) is
  # Python None, not an empty string: real's own guard at debconf.py:210
  # fails the task right after get_selections.
  it "fails a null value with real's own 'you must supply a valid vtype and value'" do
    dir, log = debconf_shim_dir("null-value")
    result = PluginSpecHelper.run("debconf", {
      "name"         => "spec.pkg",
      "question"     => "spec.pkg/keyboard-layout",
      "value"        => Krikri::NONE_SENTINEL,
      "vtype"        => "text",
      "_environment" => debconf_env(dir, log, ""),
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("when supplying a question you must supply a valid vtype and value")
    File.exists?(log).must_equal(false)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  # real's multiselect branch joins the LIST (debconf.py:241) and catches
  # its own TypeError into a fail_json rather than crashing - a different
  # message, and it sorts first, so a homogeneous non-string list always
  # names its first element.
  it "fails a multiselect list of ints with real's own caught TypeError" do
    dir, log = debconf_shim_dir("multiselect-ints")
    result = PluginSpecHelper.run("debconf", {
      "name"         => "spec.pkg",
      "question"     => "spec.pkg/multiselect",
      "value"        => "#{Krikri::NON_STRING_MEMBER_PREFIX}2,#{Krikri::NON_STRING_MEMBER_PREFIX}1",
      "vtype"        => "multiselect",
      "_environment" => debconf_env(dir, log, ""),
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Invalid value provided for 'multiselect': sequence item 0: expected str instance, int found")
    File.exists?(log).must_equal(false)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  # The join sits behind `if changed: if not module.check_mode`, so a
  # --check run never builds the line and reports changed like real.
  it "reports changed for an int value in check mode, like real's check_mode branch" do
    dir, log = debconf_shim_dir("int-value-check")
    result = PluginSpecHelper.run("debconf", {
      "name"                => "spec.pkg",
      "question"            => "spec.pkg/keyboard-layout",
      "value"               => Krikri::NON_STRING_PARAM_PREFIX + "76",
      "vtype"               => "text",
      "_ansible_check_mode" => "true",
      "_environment"        => debconf_env(dir, log, ""),
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    File.exists?(log).must_equal(false)
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
