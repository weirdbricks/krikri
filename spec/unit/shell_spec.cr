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

  describe ".quote_if_needed" do
    it "leaves shell-safe tokens byte-identical (bare words, IPs/CIDRs, port lists, multi-word values)" do
      Krikri::Shell.quote_if_needed("any").should eq("any")
      Krikri::Shell.quote_if_needed("192.168.1.0/24").should eq("192.168.1.0/24")
      Krikri::Shell.quote_if_needed("80,443").should eq("80,443")
      Krikri::Shell.quote_if_needed("10 20").should eq("10 20")
      Krikri::Shell.quote_if_needed("ESTABLISHED,RELATED").should eq("ESTABLISHED,RELATED")
      Krikri::Shell.quote_if_needed("").should eq("")
    end

    it "single-quotes anything carrying a shell metacharacter, with the apostrophe escaped" do
      Krikri::Shell.quote_if_needed("x; touch /tmp/pwned; #").should eq("'x; touch /tmp/pwned; #'")
      Krikri::Shell.quote_if_needed("it's").should eq("'it'\\''s'")
      Krikri::Shell.quote_if_needed("$(id)").should eq("'$(id)'")
      Krikri::Shell.quote_if_needed("a\nb").should eq("'a\nb'")
    end

    it "round-trips a metacharacter-bearing value through bash unchanged" do
      nasty = "it's a $(id > /tmp/krikri-spec-quote-pwn); `id` | foo;bar"
      stdout = IO::Memory.new
      process = Process.new("/bin/bash", ["-c", "printf %s #{Krikri::Shell.quote_if_needed(nasty)}"], output: stdout)
      process.wait
      stdout.to_s.should eq(nasty)
      File.exists?("/tmp/krikri-spec-quote-pwn").should be_false
    end
  end
end
