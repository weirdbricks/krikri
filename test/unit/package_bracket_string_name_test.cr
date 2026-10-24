require "../minitest_helper"
require "../../src/krikri/param_sentinels"
require "file_utils"

# Issue #300 (wangsha.ansible_role_lynis, round 29880205): a whole-span
# `{{ item }}` name over a with_items entry like
# "{% if x %}apt-transport-https{% else %}[]{% endif %}" binds item to the
# STRING "[]", and ansible's package module passes that str name whole to
# dnf, which fails the install with its own shape (live-verified on rocky:
# msg "Failed to install some of the specified packages", failures
# ["No package [] available."], rc 1). This engine's wire is strings-only,
# so the str "[]" and a real empty LIST both arrive as the text "[]" -
# previously the plugin's JSON-bracket decode read both as an empty list
# and reported ok "Nothing to do". The executor marks the string form
# (NON_STRING_PARAM_PREFIX, see substitute_task_params); these specs replay
# both shapes through the real package plugin binary against a fake dnf on
# PATH that records its own argv.
private def with_fake_dnf_backend(&)
  shim_dir = PluginSpecHelper.tmp_path("fake-dnf")
  Dir.mkdir_p(shim_dir)
  invoked_log = File.join(shim_dir, "invoked.log")
  File.write("#{shim_dir}/dnf", <<-SH
      #!/bin/sh
      printf 'dnf\n' >> #{invoked_log}
      printf '%s\n' "$@" >> #{invoked_log}
      echo "Last metadata expiration check: 0:01:10 ago on Sat Sep 19 13:26:53 2026."
      echo "No match for argument: []"
      echo "Error: Unable to find a match: []" >&2
      exit 1
    SH
  )
  File.write("#{shim_dir}/yum", <<-SH
      #!/bin/sh
      printf 'yum\n' >> #{invoked_log}
      printf '%s\n' "$@" >> #{invoked_log}
      exit 1
    SH
  )
  File.write("#{shim_dir}/rpm", <<-SH
      #!/bin/sh
      printf 'rpm\n' >> #{invoked_log}
      printf '%s\n' "$@" >> #{invoked_log}
      exit 1
    SH
  )
  {"dnf", "yum", "rpm"}.each { |name| File.chmod("#{shim_dir}/#{name}", 0o755) }
  File.delete(invoked_log) if File.exists?(invoked_log)
  yield shim_dir, invoked_log
ensure
  FileUtils.rm_r(shim_dir) if shim_dir
end

describe "package: a templated STRING '[]' name vs a real empty list" do
  it "sends the str '[]' to the backend and fails with its own shape (marked)" do
    with_fake_dnf_backend do |shim_dir, invoked_log|
      result = PluginSpecHelper.run("package",
        {"name" => Krikri::NON_STRING_PARAM_PREFIX + "[]".to_json, "state" => "present", "use" => "dnf"},
        env: {"PATH" => "#{shim_dir}:#{ENV["PATH"]}"})
      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Failed to install some of the specified packages")
      result["failures"].as_a.map(&.as_s).must_equal(["No package [] available."])
      result["rc"].as_i.must_equal(1)
      result["changed"].as_bool.must_equal(false)
      # The literal name reached dnf as its own argv element - never
      # swallowed into the empty-list no-op.
      commands = File.exists?(invoked_log) ? File.read(invoked_log) : ""
      commands.includes?("dnf\ninstall").must_equal(true, commands)
      commands.includes?("\n[]\n").must_equal(true, commands)
    end
  end

  it "still no-ops the unmarked wire text '[]' as an empty list" do
    with_fake_dnf_backend do |shim_dir, _invoked_log|
      result = PluginSpecHelper.run("package",
        {"name" => "[]", "state" => "present", "use" => "dnf"},
        env: {"PATH" => "#{shim_dir}:#{ENV["PATH"]}"})
      result["failed"]?.must_be_nil
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Nothing to do")
    end
  end
end

describe "package: marked bracket-string wire round trip" do
  it "demotes the marked STRING '[]' back to plain text and exposes the native str" do
    marked = Krikri::NON_STRING_PARAM_PREFIX + "[]".to_json
    native = Krikri.non_string_scalar(marked)
    native.try(&.as_s?).must_equal("[]")
    Krikri.strip_non_string_param_markers({"name" => marked})["name"].must_equal("[]")
  end
end
