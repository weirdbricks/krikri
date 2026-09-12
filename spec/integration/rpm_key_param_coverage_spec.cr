require "../spec_helper"
require "file_utils"

# Proactive parameter-coverage pass for the rpm_key plugin's fingerprint:
# param. rpm/dnf are NOT installed on the spec host (Debian-based), so -
# like dnf_param_coverage_spec - these specs pin the decision SHAPE only:
# a fake `gpg` emits a fixed key's colon-dump, a fake `rpm` records
# --import argv, and each example asserts the import/failure decision for
# a given fingerprint: string shape.
#
# Real ansible.builtin.rpm_key's own argument_spec types fingerprint: as
# LIST (ansible/modules/rpm_key.py), so after task-param substitution a
# real YAML list arrives at the plugin as a JSON-array-shaped STRING -
# the same wire-format situation unarchive.cr's parse_list_param
# documents (a naive comma-split produced one garbage element still
# wrapped in brackets). A comma-separated scalar stays accepted too:
# real Ansible's check_type_list accepts it for backward compat, not
# just a real list.
#
# Every expected outcome below was cross-checked against the real
# rpm_key.py fingerprint-check semantics (any supplied fingerprint
# matching ANY key in the material passes; otherwise the task fails with
# "does not match any key fingerprints"), not against a live RPM host.

FPR   = "ABCDEF0123456789ABCDEF0123456789ABCDEF01"
KEYID = "deadbeefcafeb00d"

GPG_SHIM = <<-SH
#!/bin/sh
echo "pub::::#{KEYID}:::"
echo "fpr:::::::::#{FPR}:"
exit 0
SH

RPM_SHIM = <<-'SH'
#!/bin/sh
if [ "$1" = "-q" ]; then
  exit 1
fi
if [ "$1" = "--import" ]; then
  printf '%s\n' "$*" >> "${KRIKRI_FAKE_RPM_LOG:?}"
  exit 0
fi
exit 1
SH

# Installs fake `gpg` (fixed colon-dump for any key file) and `rpm`
# (always "no gpg-pubkey packages installed" for -q, records --import
# argv) at the front of PATH. The plugin's local remote_exec shells out
# via bash and inherits the spec process's environment.
def with_rpm_key_shims(&)
  bin_dir = File.tempname("krikri-fake-rpmkey")
  Dir.mkdir_p(bin_dir)
  gpg = File.join(bin_dir, "gpg")
  File.write(gpg, GPG_SHIM)
  File.chmod(gpg, 0o755)
  rpm = File.join(bin_dir, "rpm")
  File.write(rpm, RPM_SHIM)
  File.chmod(rpm, 0o755)

  log = File.tempname("krikri-fake-rpmkey-log")
  previous_path = ENV["PATH"]?
  previous_log = ENV["KRIKRI_FAKE_RPM_LOG"]?
  ENV["PATH"] = "#{bin_dir}:#{ENV["PATH"]?}"
  ENV["KRIKRI_FAKE_RPM_LOG"] = log
  begin
    yield log
  ensure
    previous_path ? (ENV["PATH"] = previous_path) : ENV.delete("PATH")
    previous_log ? (ENV["KRIKRI_FAKE_RPM_LOG"] = previous_log) : ENV.delete("KRIKRI_FAKE_RPM_LOG")
    FileUtils.rm_r(bin_dir)
    File.delete(log) if File.exists?(log)
  end
end

def with_key_file(&)
  path = File.tempname("krikri-spec-rpm-key")
  File.write(path, "fake key material\n")
  begin
    yield path
  ensure
    File.delete(path) rescue nil
  end
end

describe "rpm_key plugin fingerprint param" do
  it "accepts a JSON-array-shaped list (a real YAML list after task-param substitution)" do
    with_rpm_key_shims do
      with_key_file do |key_path|
        result = PluginSpecHelper.run("rpm_key", {
          "key"         => key_path,
          "fingerprint" => %(["#{FPR}"]),
        })
        result["failed"].as_bool.should be_false
        result["changed"].as_bool.should be_true
        result["msg"].as_s.should contain("imported")
      end
    end
  end

  it "accepts a Python-repr list (single-quoted, from a Jinja template render)" do
    with_rpm_key_shims do
      with_key_file do |key_path|
        result = PluginSpecHelper.run("rpm_key", {
          "key"         => key_path,
          "fingerprint" => "['#{FPR}']",
        })
        result["failed"].as_bool.should be_false
        result["changed"].as_bool.should be_true
      end
    end
  end

  it "accepts a comma-separated fingerprint string (real Ansible's check_type_list backward compat)" do
    with_rpm_key_shims do
      with_key_file do |key_path|
        result = PluginSpecHelper.run("rpm_key", {
          "key"         => key_path,
          "fingerprint" => "0000000000000000000000000000000000000000,#{FPR}",
        })
        result["failed"].as_bool.should be_false
        result["changed"].as_bool.should be_true
        result["msg"].as_s.should contain("imported")
      end
    end
  end

  it "normalizes fingerprints with embedded spaces like real Ansible" do
    spaced = FPR.scan(/.{4}/).map(&.[0]).join(" ")
    with_rpm_key_shims do
      with_key_file do |key_path|
        result = PluginSpecHelper.run("rpm_key", {
          "key"         => key_path,
          "fingerprint" => spaced,
        })
        result["failed"].as_bool.should be_false
        result["changed"].as_bool.should be_true
      end
    end
  end

  it "fails and does not import when a JSON-array fingerprint list matches no key" do
    with_rpm_key_shims do |log|
      with_key_file do |key_path|
        result = PluginSpecHelper.run("rpm_key", {
          "key"         => key_path,
          "fingerprint" => %(["0000000000000000000000000000000000000000"]),
        })
        result["failed"].as_bool.should be_true
        result["msg"].as_s.should contain("does not match any key fingerprints")
        (!File.exists?(log) || File.read(log).empty?).should be_true
      end
    end
  end
end
