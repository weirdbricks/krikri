require "../../src/krikri/plugin_helpers/cron_var"

private alias CronVar = Krikri::PluginHelpers::CronVar

describe CronVar do
  describe ".parse_var_line" do
    it "parses a plain assignment" do
      CronVar.parse_var_line("MAILTO=root").should eq({"MAILTO", "root"})
    end

    it "parses an assignment with spaces around the =" do
      CronVar.parse_var_line("MAILTO = root").should eq({"MAILTO", "root"})
    end

    it "parses with leading whitespace" do
      CronVar.parse_var_line("  PATH=/usr/bin").should eq({"PATH", "/usr/bin"})
    end

    it "rejects a name that merely shares a prefix (exact token match)" do
      CronVar.parse_var_line("FOOBAR=baz").try(&.[0]).should_not eq("FOO")
    end

    it "rejects crontab schedule lines" do
      CronVar.parse_var_line("0 2 * * * /bin/backup").should be_nil
      CronVar.parse_var_line("* * * * * /bin/true").should be_nil
      CronVar.parse_var_line("@reboot /bin/true").should be_nil
    end

    it "rejects comments and blank lines" do
      CronVar.parse_var_line("#Ansible: some job").should be_nil
      CronVar.parse_var_line("#FOO=bar").should be_nil
      CronVar.parse_var_line("").should be_nil
      CronVar.parse_var_line("   ").should be_nil
    end

    it "preserves quoted spaces in the value but swallows unquoted ones (real module's shlex quirk)" do
      CronVar.parse_var_line(%(FOO='bar baz')).should eq({"FOO", "bar baz"})
      CronVar.parse_var_line(%(FOO="bar baz")).should eq({"FOO", "bar baz"})
      CronVar.parse_var_line("FOO=bar baz").should eq({"FOO", "barbaz"})
    end

    it "treats an unquoted word after a space as breaking the assignment" do
      CronVar.parse_var_line("FOO BAR=1").should be_nil
    end
  end

  describe ".find_variable" do
    it "finds the first assignment with the exact name" do
      text = "SHELL=/bin/sh\nMAILTO=root\nFOO=1\n"
      CronVar.find_variable(text, "MAILTO").should eq("root")
      CronVar.find_variable(text, "FOO").should eq("1")
      CronVar.find_variable(text, "NOPE").should be_nil
    end

    it "does not match a variable whose name has the target as a prefix" do
      CronVar.find_variable("FOOBAR=1\n", "FOO").should be_nil
    end

    it "is case-sensitive" do
      CronVar.find_variable("foo=bar\n", "FOO").should be_nil
    end
  end

  describe ".var_names" do
    it "lists assignment names in file order, skipping non-assignments" do
      text = "#Ansible: job\n0 2 * * * /bin/x\nMAILTO=root\nSHELL=/bin/sh\n"
      CronVar.var_names(text).should eq(["MAILTO", "SHELL"])
    end
  end

  describe ".upsert" do
    it "adds a new variable at the top of the file (real add_variable behavior)" do
      text, changed = CronVar.upsert("MAILTO=root\n", "PATH", "/usr/bin")
      changed.should be_true
      text.should eq("PATH=/usr/bin\nMAILTO=root\n")
    end

    it "adds the first variable to an empty file" do
      text, changed = CronVar.upsert("", "MAILTO", "root")
      changed.should be_true
      text.should eq("MAILTO=root\n")
    end

    it "is a no-op when the variable already has the value" do
      text, changed = CronVar.upsert("MAILTO=root\n", "MAILTO", "root")
      changed.should be_false
      text.should eq("MAILTO=root\n")
    end

    it "updates an assignment in place" do
      text, changed = CronVar.upsert("MAILTO=root\nSHELL=/bin/sh\n", "MAILTO", "admin@example.com")
      changed.should be_true
      text.should eq("MAILTO=admin@example.com\nSHELL=/bin/sh\n")
    end

    it "does not rewrite an assignment that already holds the value, even with spaces around the = (real module only rewrites when the parsed value differs)" do
      text, changed = CronVar.upsert("MAILTO = root\n", "MAILTO", "root")
      changed.should be_false
      text.should eq("MAILTO = root\n")
    end

    it "updates every duplicate occurrence, but compares only the first" do
      original = "FOO=1\nSHELL=/bin/sh\nFOO=2\n"
      _, changed = CronVar.upsert(original, "FOO", "1")
      changed.should be_false

      text, changed = CronVar.upsert(original, "FOO", "9")
      changed.should be_true
      text.should eq("FOO=9\nSHELL=/bin/sh\nFOO=9\n")
    end

    it "removes the variable with state=absent semantics" do
      text, changed = CronVar.upsert("MAILTO=root\nSHELL=/bin/sh\n", "MAILTO", nil)
      changed.should be_true
      text.should eq("SHELL=/bin/sh\n")
    end

    it "removes every duplicate occurrence" do
      text, changed = CronVar.upsert("FOO=1\nSHELL=/bin/sh\nFOO=2\n", "FOO", nil)
      changed.should be_true
      text.should eq("SHELL=/bin/sh\n")
    end

    it "is a no-op removing a variable that isn't there" do
      text, changed = CronVar.upsert("SHELL=/bin/sh\n", "MAILTO", nil)
      changed.should be_false
      text.should eq("SHELL=/bin/sh\n")
    end

    it "leaves schedule lines and other variables untouched" do
      original = "SHELL=/bin/sh\n#Ansible: backup\n0 2 * * * /bin/backup\n"
      text, changed = CronVar.upsert(original, "MAILTO", "root")
      changed.should be_true
      text.should eq("MAILTO=root\nSHELL=/bin/sh\n#Ansible: backup\n0 2 * * * /bin/backup\n")
    end

    it "inserts after the named variable with insertafter" do
      text, changed = CronVar.upsert("A=1\nB=2\n", "C", "3", nil, "A")
      changed.should be_true
      text.should eq("A=1\nC=3\nB=2\n")
    end

    it "inserts before the named variable with insertbefore" do
      text, changed = CronVar.upsert("A=1\nB=2\n", "C", "3", "B", nil)
      changed.should be_true
      text.should eq("A=1\nC=3\nB=2\n")
    end

    it "reproduces the real module's quirk: a missing insertafter target silently drops the new variable but reports changed" do
      text, changed = CronVar.upsert("A=1\n", "C", "3", nil, "NOSUCH")
      changed.should be_true
      text.should eq("A=1\n")
    end

    it "renders an empty value as the two-character literal \"\" (real main() quirk)" do
      text, changed = CronVar.upsert("MAILTO=root\n", "MAILTO", "")
      changed.should be_true
      text.should eq("MAILTO=\"\"\n")

      _, changed = CronVar.upsert(%(MAILTO=""), "MAILTO", "")
      changed.should be_false
    end
  end
end
