require "../spec_helper"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp")

Spec.before_suite do
  Dir.mkdir_p(TMP_DIR)
end

private def tmp_path(name : String) : String
  File.join(TMP_DIR, name)
end

describe "lineinfile plugin" do
  it "receives its config over stdin (regression: used to read argv and silently do nothing)" do
    path = tmp_path("lineinfile-stdin.txt")
    File.write(path, "existing line\n")

    result = PluginSpecHelper.run("lineinfile", {
      "path"  => path,
      "line"  => "new line",
      "state" => "present",
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_true
    File.read(path).should contain("new line")
  end

  it "is idempotent when the line already exists" do
    path = tmp_path("lineinfile-idempotent.txt")
    File.write(path, "hello world\n")

    result = PluginSpecHelper.run("lineinfile", {
      "path"  => path,
      "line"  => "hello world",
      "state" => "present",
    })

    result["changed"].as_bool.should be_false
  end

  it "removes a matching line when state=absent" do
    path = tmp_path("lineinfile-absent.txt")
    File.write(path, "keep me\nremove me\n")

    result = PluginSpecHelper.run("lineinfile", {
      "path"  => path,
      "line"  => "remove me",
      "state" => "absent",
    })

    result["changed"].as_bool.should be_true
    content = File.read(path)
    content.should contain("keep me")
    content.should_not contain("remove me")
  end

  it "does not write to disk in check mode" do
    path = tmp_path("lineinfile-check-mode.txt")
    File.write(path, "original\n")

    result = PluginSpecHelper.run("lineinfile", {
      "path"       => path,
      "line"       => "added line",
      "state"      => "present",
      "check_mode" => "true",
    })

    result["changed"].as_bool.should be_true
    File.read(path).should eq("original\n")
  end

  it "does not introduce a spurious blank line when appending to a file that already ends with a newline" do
    # Regression (found via the Ansible compat harness, compat/run.cr):
    # split("\n") always adds one trailing "" artifact when content ends
    # with "\n" - a previous version of the pop-that-artifact guard was
    # conditioned on the negation of exactly the case where it needed to
    # fire, so it never actually popped anything, leaving a blank line
    # before every appended line.
    path = tmp_path("lineinfile-no-spurious-blank.txt")
    File.write(path, "first line\nsecond line\n")

    PluginSpecHelper.run("lineinfile", {"path" => path, "line" => "third line", "state" => "present"})

    File.read(path).should eq("first line\nsecond line\nthird line\n")
  end

  it "does not leave a spurious blank line behind after removing a line" do
    path = tmp_path("lineinfile-remove-no-blank.txt")
    File.write(path, "first line\nsecond line\nthird line\n")

    PluginSpecHelper.run("lineinfile", {"path" => path, "line" => "first line", "state" => "absent"})

    File.read(path).should eq("second line\nthird line\n")
  end

  it "fails with a clear message when the file does not exist and create is not set" do
    path = tmp_path("lineinfile-missing.txt")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("lineinfile", {
      "path" => path,
      "line" => "hello",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("does not exist")
  end
end
