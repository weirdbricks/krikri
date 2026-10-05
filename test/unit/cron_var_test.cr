require "../minitest_helper"
require "../../src/krikri/plugin_helpers/cron_var"

private alias CronVar = Krikri::PluginHelpers::CronVar

describe CronVar do
  describe ".parse_var_line" do
    it "parses a plain assignment" do
      CronVar.parse_var_line("MAILTO=root").must_equal({"MAILTO", "root"})
    end

    it "parses an assignment with spaces around the =" do
      CronVar.parse_var_line("MAILTO = root").must_equal({"MAILTO", "root"})
    end

    it "parses with leading whitespace" do
      CronVar.parse_var_line("  PATH=/usr/bin").must_equal({"PATH", "/usr/bin"})
    end

    it "rejects a name that merely shares a prefix (exact token match)" do
      CronVar.parse_var_line("FOOBAR=baz").try(&.[0]).wont_equal("FOO")
    end

    it "rejects crontab schedule lines" do
      CronVar.parse_var_line("0 2 * * * /bin/backup").must_be_nil
      CronVar.parse_var_line("* * * * * /bin/true").must_be_nil
      CronVar.parse_var_line("@reboot /bin/true").must_be_nil
    end

    it "rejects comments and blank lines" do
      CronVar.parse_var_line("#Ansible: some job").must_be_nil
      CronVar.parse_var_line("#FOO=bar").must_be_nil
      CronVar.parse_var_line("").must_be_nil
      CronVar.parse_var_line("   ").must_be_nil
    end

    it "preserves quoted spaces in the value but swallows unquoted ones (real module's shlex quirk)" do
      CronVar.parse_var_line(%(FOO='bar baz')).must_equal({"FOO", "bar baz"})
      CronVar.parse_var_line(%(FOO="bar baz")).must_equal({"FOO", "bar baz"})
      CronVar.parse_var_line("FOO=bar baz").must_equal({"FOO", "barbaz"})
    end

    it "treats an unquoted word after a space as breaking the assignment" do
      CronVar.parse_var_line("FOO BAR=1").must_be_nil
    end
  end

  describe ".find_variable" do
    it "finds the first assignment with the exact name" do
      text = "SHELL=/bin/sh\nMAILTO=root\nFOO=1\n"
      CronVar.find_variable(text, "MAILTO").must_equal("root")
      CronVar.find_variable(text, "FOO").must_equal("1")
      CronVar.find_variable(text, "NOPE").must_be_nil
    end

    it "does not match a variable whose name has the target as a prefix" do
      CronVar.find_variable("FOOBAR=1\n", "FOO").must_be_nil
    end

    it "is case-sensitive" do
      CronVar.find_variable("foo=bar\n", "FOO").must_be_nil
    end
  end

  describe ".var_names" do
    it "lists assignment names in file order, skipping non-assignments" do
      text = "#Ansible: job\n0 2 * * * /bin/x\nMAILTO=root\nSHELL=/bin/sh\n"
      CronVar.var_names(text).must_equal(["MAILTO", "SHELL"])
    end
  end

  describe ".upsert" do
    it "adds a new variable at the top of the file (real add_variable behavior)" do
      text, changed = CronVar.upsert("MAILTO=root\n", "PATH", "/usr/bin")
      changed.must_equal(true)
      text.must_equal("PATH=/usr/bin\nMAILTO=root\n")
    end

    it "adds the first variable to an empty file" do
      text, changed = CronVar.upsert("", "MAILTO", "root")
      changed.must_equal(true)
      text.must_equal("MAILTO=root\n")
    end

    it "is a no-op when the variable already has the value" do
      text, changed = CronVar.upsert("MAILTO=root\n", "MAILTO", "root")
      changed.must_equal(false)
      text.must_equal("MAILTO=root\n")
    end

    it "updates an assignment in place" do
      text, changed = CronVar.upsert("MAILTO=root\nSHELL=/bin/sh\n", "MAILTO", "admin@example.com")
      changed.must_equal(true)
      text.must_equal("MAILTO=admin@example.com\nSHELL=/bin/sh\n")
    end

    it "does not rewrite an assignment that already holds the value, even with spaces around the = (real module only rewrites when the parsed value differs)" do
      text, changed = CronVar.upsert("MAILTO = root\n", "MAILTO", "root")
      changed.must_equal(false)
      text.must_equal("MAILTO = root\n")
    end

    it "updates every duplicate occurrence, but compares only the first" do
      original = "FOO=1\nSHELL=/bin/sh\nFOO=2\n"
      _, changed = CronVar.upsert(original, "FOO", "1")
      changed.must_equal(false)

      text, changed = CronVar.upsert(original, "FOO", "9")
      changed.must_equal(true)
      text.must_equal("FOO=9\nSHELL=/bin/sh\nFOO=9\n")
    end

    it "removes the variable with state=absent semantics" do
      text, changed = CronVar.upsert("MAILTO=root\nSHELL=/bin/sh\n", "MAILTO", nil)
      changed.must_equal(true)
      text.must_equal("SHELL=/bin/sh\n")
    end

    it "removes every duplicate occurrence" do
      text, changed = CronVar.upsert("FOO=1\nSHELL=/bin/sh\nFOO=2\n", "FOO", nil)
      changed.must_equal(true)
      text.must_equal("SHELL=/bin/sh\n")
    end

    it "is a no-op removing a variable that isn't there" do
      text, changed = CronVar.upsert("SHELL=/bin/sh\n", "MAILTO", nil)
      changed.must_equal(false)
      text.must_equal("SHELL=/bin/sh\n")
    end

    it "leaves schedule lines and other variables untouched" do
      original = "SHELL=/bin/sh\n#Ansible: backup\n0 2 * * * /bin/backup\n"
      text, changed = CronVar.upsert(original, "MAILTO", "root")
      changed.must_equal(true)
      text.must_equal("MAILTO=root\nSHELL=/bin/sh\n#Ansible: backup\n0 2 * * * /bin/backup\n")
    end

    it "inserts after the named variable with insertafter" do
      text, changed = CronVar.upsert("A=1\nB=2\n", "C", "3", nil, "A")
      changed.must_equal(true)
      text.must_equal("A=1\nC=3\nB=2\n")
    end

    it "inserts before the named variable with insertbefore" do
      text, changed = CronVar.upsert("A=1\nB=2\n", "C", "3", "B", nil)
      changed.must_equal(true)
      text.must_equal("A=1\nC=3\nB=2\n")
    end

    it "reproduces the Ansible module's quirk: a missing insertafter target silently drops the new variable but reports changed" do
      text, changed = CronVar.upsert("A=1\n", "C", "3", nil, "NOSUCH")
      changed.must_equal(true)
      text.must_equal("A=1\n")
    end

    it "renders an empty value as the two-character literal \"\" (real main() quirk)" do
      text, changed = CronVar.upsert("MAILTO=root\n", "MAILTO", "")
      changed.must_equal(true)
      text.must_equal("MAILTO=\"\"\n")

      _, changed = CronVar.upsert(%(MAILTO=""), "MAILTO", "")
      changed.must_equal(false)
    end
  end
end
