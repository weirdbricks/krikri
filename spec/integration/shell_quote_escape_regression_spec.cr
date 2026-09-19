require "../spec_helper"
require "file_utils"

# Regression spec for the broken double-backslash single-quote escape
# (`"'" + s.gsub("'", "'\\\\''") + "'"`), which emitted a literal `\\`
# instead of the POSIX `'\''` convention - so any embedded apostrophe
# terminated the quoting context early and let the rest of the value
# run as shell code. Both local helper copies (make's shell_quote/
# shlex_quote, debconf's shell_single_quote) now go through
# Krikri::Shell.single_quote. Live-confirmed injection pre-fix: a debconf
# `value` of "x' | touch <marker> #" created the marker file.

private def marker_shim_env(dir : String) : String
  {
    "PATH"                => "#{dir}:/usr/bin:/bin",
    "KRIKRI_DEBCONF_SHOW" => File.join(dir, "show.txt"),
    "KRIKRI_DEBCONF_LOG"  => File.join(dir, "set-selections.log"),
  }.to_json
end

private def debconf_shim_dir(name : String) : String
  dir = File.join(Dir.tempdir, "krikri-quote-escape-#{name}-#{Random.rand(1_000_000)}")
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "debconf-show"), "#!/bin/sh\ncat \"$KRIKRI_DEBCONF_SHOW\"\n")
  File.write(File.join(dir, "debconf-set-selections"), "#!/bin/sh\ncat >> \"$KRIKRI_DEBCONF_LOG\"\n")
  File.write(File.join(dir, "debconf-get-selections"), "#!/bin/sh\ntrue\n")
  {"debconf-show", "debconf-set-selections", "debconf-get-selections"}.each do |bin|
    File.chmod(File.join(dir, bin), 0o755)
  end
  File.write(File.join(dir, "show.txt"), "")
  dir
end

describe "POSIX single-quote escaping (Shell.single_quote) in plugins" do
  it "does not let a debconf value escape its quoting context (no marker file)" do
    dir = debconf_shim_dir("injection")
    marker = File.join(dir, "pwn_marker")
    log = File.join(dir, "set-selections.log")

    result = PluginSpecHelper.run("debconf", {
      "name"         => "spec.pkg",
      "question"     => "spec.pkg/keyboard-layout",
      "vtype"        => "string",
      "value"        => "x' | touch #{marker} #",
      "_environment" => marker_shim_env(dir),
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    File.exists?(marker).should be_false
    File.read(log).strip.should eq("spec.pkg spec.pkg/keyboard-layout string x' | touch #{marker} #")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "still passes a legitimate apostrophe value through to debconf verbatim" do
    dir = debconf_shim_dir("apostrophe")
    log = File.join(dir, "set-selections.log")

    result = PluginSpecHelper.run("debconf", {
      "name"         => "spec.pkg",
      "question"     => "spec.pkg/motd",
      "vtype"        => "string",
      "value"        => "It's fine",
      "_environment" => marker_shim_env(dir),
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_true
    File.read(log).strip.should eq("spec.pkg spec.pkg/motd string It's fine")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "does not let a make chdir escape its quoting context (no marker file)" do
    dir = File.join(Dir.tempdir, "krikri-quote-escape-make-#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(dir)
    marker = File.join(dir, "pwn_marker")

    PluginSpecHelper.run("make", {
      "chdir" => "x' | touch #{marker} #",
      "make"  => "/bin/true",
    })

    File.exists?(marker).should be_false
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "still builds a make project living in a directory with an apostrophe" do
    dir = File.join(Dir.tempdir, "krikri-quote-escape-make-apos-#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(dir)
    chdir = File.join(dir, "someone's project")
    Dir.mkdir_p(chdir)
    File.write(File.join(chdir, "Makefile"), "all:\n\t@echo built-ok\n")

    result = PluginSpecHelper.run("make", {"chdir" => chdir, "target" => "all"})

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_true
    result["stdout"].as_s.should eq("built-ok")
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
