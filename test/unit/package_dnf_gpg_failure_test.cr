require "../minitest_helper"
require "file_utils"
require "json"

# Issue #329 (Rocky 9, `package: name: <https .rpm URL>` whose GPG key
# isn't installed): ansible's dnf backend validates the signature of each
# downloaded rpm itself BEFORE the transaction, then fails through a bare
# fail_json - ONLY msg "Failed to validate GPG signature for <nevra>: <key
# error>", with no stderr/rc/failures/results keys and no raw-output dump.
# dnf 4.14 (EL9) never prints "Failing package is:", so the failing nevra
# only shows up as the transaction table's @commandline row; the CLI's own
# lines around it (live-captured from Rocky:
#
#   Public key for <file>.rpm is not installed
#   Error: GPG check FAILED
#
# ) fed `package:`'s dnf_install_failure_result into its generic "Failed
# to install <url>: <stderr>" shape plus a stderr key instead.
PGDG_TABLE_STDOUT = " Package          Arch     Version     Repository     Size\nInstalling:\n pgdg-redhat-repo     noarch   42.0-70.rhel9PGDG    @commandline   18 k\n"
PGDG_KEY_STDERR   = "Public key for pgdg-redhat-repo-42.0-70.rhel9PGDG.noarch.rpm is not installed\nError: GPG check FAILED\n"
PGDG_GPG_MSG      = "Failed to validate GPG signature for pgdg-redhat-repo-42.0-70.rhel9PGDG.noarch: Public key for pgdg-redhat-repo-42.0-70.rhel9PGDG.noarch.rpm is not installed"
PGDG_URL          = "https://localhost/pgdg-redhat-repo-42.0-70.rhel9PGDG.noarch.rpm"

private def with_gpg_failing_dnf_shim(stdout : String, stderr : String, &)
  shim_dir = PluginSpecHelper.tmp_path("fake-dnf-gpg-fail")
  Dir.mkdir_p(shim_dir)
  script = "#!/bin/sh\ncat <<'KRIKRI_FAKE_DNF_EOF'\n#{stdout}KRIKRI_FAKE_DNF_EOF\n"
  script += stderr.lines.map { |line| "echo '#{line.gsub("'", "'\\''")}' >&2" }.join("\n") + "\n" unless stderr.empty?
  script += "exit 1\n"
  File.write("#{shim_dir}/dnf", script)
  File.chmod("#{shim_dir}/dnf", 0o755)
  # `package:` shells `dnf install ... || yum install ...`, so yum needs
  # an equally failing shim or the compound would exit 0.
  File.write("#{shim_dir}/yum", script)
  File.chmod("#{shim_dir}/yum", 0o755)
  PluginSpecHelper::ENV_MUTEX.synchronize do
    old_path = ENV["PATH"]?
    ENV["PATH"] = "#{shim_dir}:#{old_path}"
    begin
      yield
    ensure
      old_path ? (ENV["PATH"] = old_path) : (ENV.delete("PATH"))
    end
  end
ensure
  FileUtils.rm_r(shim_dir) if shim_dir
end

describe "package: unsigned .rpm install - ansible's bare GPG-validation msg (issue 329)" do
  serial!

  it "reports the bare GPG msg, no stderr key (present)" do
    with_gpg_failing_dnf_shim(PGDG_TABLE_STDOUT, PGDG_KEY_STDERR) do
      result = PluginSpecHelper.run("package",
        {"name" => PGDG_URL, "state" => "present", "use" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(PGDG_GPG_MSG)
      result.as_h.has_key?("stderr").must_equal(false)
      result.as_h.has_key?("failures").must_equal(false)
      result.as_h.has_key?("rc").must_equal(false)
      result.as_h.has_key?("results").must_equal(false)
    end
  end

  it "reports the same failure from package: state latest" do
    # The latest branch fails unresolvable/failed transactions through
    # the same dnf_install_failure_result the present branch reports.
    with_gpg_failing_dnf_shim(PGDG_TABLE_STDOUT, PGDG_KEY_STDERR) do
      result = PluginSpecHelper.run("package",
        {"name" => PGDG_URL, "state" => "latest", "use" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(PGDG_GPG_MSG)
      result.as_h.has_key?("stderr").must_equal(false)
    end
  end
end
