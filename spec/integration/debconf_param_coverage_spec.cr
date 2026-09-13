require "../spec_helper"
require "file_utils"

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

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are required together: question, vtype, value")
    File.exists?(log).should be_false
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

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are required together: question, vtype, value")
    File.exists?(log).should be_false
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

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are required together: question, vtype, value")
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

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_true
    result["msg"].as_s.should eq("Value set")
    File.read(log).strip.should eq("spec.pkg spec.pkg/keyboard-layout string de")
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

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_false
    result["msg"].as_s.should eq("Value already set")
    File.exists?(log).should be_false
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
