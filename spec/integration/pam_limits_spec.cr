require "../spec_helper"
require "file_utils"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "pam_limits")

Spec.before_suite do
  FileUtils.rm_rf(TMP_DIR) if Dir.exists?(TMP_DIR)
  Dir.mkdir_p(TMP_DIR)
end

private def dest_path(name : String = "limits.d") : String
  File.join(TMP_DIR, name)
end

describe "pam_limits plugin" do
  it "appends an entry to a new file" do
    dest = dest_path("new.conf")

    result = PluginSpecHelper.run("pam_limits", {
      "dest" => dest, "domain" => "*", "limit_type" => "hard",
      "limit_item" => "core", "value" => "0",
    })

    result["changed"].as_bool.should be_true
    File.read(dest).should contain("*\thard\tcore\t0")
  end

  it "is idempotent on an exact rerun" do
    dest = dest_path("idem.conf")
    params = {"dest" => dest, "domain" => "*", "limit_type" => "hard",
              "limit_item" => "core", "value" => "0"}
    PluginSpecHelper.run("pam_limits", params)

    result = PluginSpecHelper.run("pam_limits", params)

    result["changed"].as_bool.should be_false
  end

  it "updates an existing entry with a different value" do
    dest = dest_path("update.conf")
    File.write(dest, "*\thard\tcore\t1\n")

    result = PluginSpecHelper.run("pam_limits", {
      "dest" => dest, "domain" => "*", "limit_type" => "hard",
      "limit_item" => "core", "value" => "0",
    })

    result["changed"].as_bool.should be_true
    File.read(dest).should contain("*\thard\tcore\t0")
  end

  it "attaches a comment as a trailing \\t#comment on the SAME line, not a separate line above it" do
    # Real bug found benchmarking robertdebock.ulimit (round 110): real
    # pam_limits.py's own write is `f"{domain}\t{limit_type}\t
    # {limit_item}\t{new_value}{new_comment}\n"` with `new_comment =
    # f"\t#{comment}"` - a trailing inline comment on the entry's own
    # line. This plugin previously wrote the comment as its own
    # SEPARATE preceding line ("# comment"), a format real Ansible
    # never produces.
    dest = dest_path("comment.conf")

    result = PluginSpecHelper.run("pam_limits", {
      "dest" => dest, "domain" => "*", "limit_type" => "hard",
      "limit_item" => "nproc", "value" => "4096", "comment" => "raise process limit",
    })

    result["changed"].as_bool.should be_true
    File.read(dest).should eq("*\thard\tnproc\t4096\t#raise process limit\n")
  end

  it "appends a brand new entry at the true end of the file, not before a '# End of file' marker" do
    # Real Ansible's own module has no special-casing for a `# End of
    # file` marker (or any other comment line) anywhere in the file -
    # it copies every existing line through unchanged and only ever
    # appends the new entry after the whole file. This plugin
    # previously inserted BEFORE that marker instead, an invented
    # behavior not in the real module at all.
    dest = dest_path("eof_marker.conf")
    File.write(dest, "*\tsoft\tnofile\t1024\n\n# End of file\n")

    result = PluginSpecHelper.run("pam_limits", {
      "dest" => dest, "domain" => "*", "limit_type" => "hard",
      "limit_item" => "nproc", "value" => "4096",
    })

    result["changed"].as_bool.should be_true
    File.read(dest).should eq("*\tsoft\tnofile\t1024\n\n# End of file\n*\thard\tnproc\t4096\n")
  end

  it "preserves an existing entry's own comment when updating its value without a new comment" do
    dest = dest_path("preserve_comment.conf")
    File.write(dest, "*\thard\tcore\t1\t#old comment\n")

    result = PluginSpecHelper.run("pam_limits", {
      "dest" => dest, "domain" => "*", "limit_type" => "hard",
      "limit_item" => "core", "value" => "0",
    })

    result["changed"].as_bool.should be_true
    File.read(dest).should eq("*\thard\tcore\t0\t#old comment\n")
  end

  it "fails when required params are missing" do
    result = PluginSpecHelper.run("pam_limits", {"domain" => "*"})
    result["failed"].as_bool.should be_true
  end
end
