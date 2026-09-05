require "../spec_helper"
require "../../src/krikri/shell"

# The one shared shell-quoting primitive (was four independently-maintained
# copies - one of which, PluginHelpers::IptablesCommand's, had drifted into a
# double-backslash escape that broke any comment containing an apostrophe).
describe Krikri::Shell do
  describe ".single_quote" do
    it "wraps a plain value in single quotes" do
      Krikri::Shell.single_quote("hello").should eq("'hello'")
    end

    it "escapes an embedded single quote using the POSIX '\\'' convention" do
      Krikri::Shell.single_quote("it's").should eq("'it'\\''s'")
    end

    it "survives every shell metacharacter - the quoted value must round-trip through bash unchanged" do
      # Round-trip through a real /bin/bash -c like the remote path does
      # (SSHManager.exec wraps commands in `bash -c <quoted>`, and
      # LocalExecutor.exec routes metacharacter-bearing strings through
      # the same shape), so the spec proves actual shell semantics, not
      # just string shape.
      nasty = "it's a $(rm -rf /tmp/x); `id` & | foo;bar\\baz * ? [x] ~ $HOME \"dq\""
      stdout = IO::Memory.new
      process = Process.new("/bin/bash", ["-c", "printf %s #{Krikri::Shell.single_quote(nasty)}"], output: stdout)
      process.wait
      stdout.to_s.should eq(nasty)
    end

    it "handles an empty string" do
      Krikri::Shell.single_quote("").should eq("''")
    end

    it "handles a value that is only single quotes (round-trips through bash)" do
      value = "'''"
      stdout = IO::Memory.new
      process = Process.new("/bin/bash", ["-c", "printf %s #{Krikri::Shell.single_quote(value)}"], output: stdout)
      process.wait
      stdout.to_s.should eq(value)
    end
  end
end
