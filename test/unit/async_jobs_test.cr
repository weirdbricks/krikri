require "../minitest_helper"
require "file_utils"
require "../../src/krikri/async_jobs"

# Every example that writes or sweeps job files runs with ANSIBLE_ASYNC_DIR
# pointed at a fresh temp directory - without this, cleanup_all sweeps the
# developer's REAL ~/.ansible_async, destroying in-flight real-Ansible job
# files and any other concurrently running test process's job files.
# The env var is set before, restored (or deleted) after, in ensure.
private def in_temp_async_dir(&)
  original = ENV["ANSIBLE_ASYNC_DIR"]?
  dir = File.join(Dir.tempdir, "krikri-async-jobs-spec-#{Random::Secure.hex(4)}")
  ENV["ANSIBLE_ASYNC_DIR"] = dir
  yield dir
ensure
  original ? (ENV["ANSIBLE_ASYNC_DIR"] = original) : ENV.delete("ANSIBLE_ASYNC_DIR")
  FileUtils.rm_rf(dir) if dir
end

describe Krikri::AsyncJobs do
  serial! # sets ANSIBLE_ASYNC_DIR / HOME (process-wide ENV)

  it "generates unique job ids" do
    jids = Array.new(20) { Krikri::AsyncJobs.generate_jid }
    jids.uniq.size.must_equal(20)
  end

  it "accepts generated and probe-shaped jids as valid" do
    Krikri::AsyncJobs.valid_jid?(Krikri::AsyncJobs.generate_jid).must_equal(true)
    Krikri::AsyncJobs.valid_jid?("no-such-job-#{Krikri::AsyncJobs.generate_jid}").must_equal(true)
    Krikri::AsyncJobs.valid_jid?("12345.67890123").must_equal(true)
  end

  it "rejects jids that could carry path traversal into a file path" do
    ["", "..", "../x", "a/b", "/etc/passwd", "../../../etc/passwd", ".", "..foo", "a\\b"].each do |bad|
      Krikri::AsyncJobs.valid_jid?(bad).must_equal(false)
      assert_raises(Krikri::AsyncJobs::InvalidJidError) { Krikri::AsyncJobs.status_path(bad) }
      assert_raises(Krikri::AsyncJobs::InvalidJidError) { Krikri::AsyncJobs.config_path(bad) }
    end
  end

  it "returns nil for a job that was never written" do
    in_temp_async_dir do
      Krikri::AsyncJobs.read_status("no-such-job-#{Krikri::AsyncJobs.generate_jid}").must_be_nil
    end
  end

  it "cleanup removes one job's status and config files" do
    in_temp_async_dir do
      jid = Krikri::AsyncJobs.generate_jid
      Krikri::AsyncJobs.write_status(jid, JSON.parse({"finished" => 1}.to_json))
      File.write(Krikri::AsyncJobs.config_path(jid), "{}")

      Krikri::AsyncJobs.cleanup(jid).must_equal(true)
      File.exists?(Krikri::AsyncJobs.status_path(jid)).must_equal(false)
      File.exists?(Krikri::AsyncJobs.config_path(jid)).must_equal(false)
      # Second cleanup finds nothing - reports false, no error.
      Krikri::AsyncJobs.cleanup(jid).must_equal(false)
    end
  end

  it "cleanup_all sweeps every job file including stray tmp leftovers" do
    in_temp_async_dir do
      jid_a = Krikri::AsyncJobs.generate_jid
      jid_b = Krikri::AsyncJobs.generate_jid
      Krikri::AsyncJobs.write_status(jid_a, JSON.parse({"finished" => 1}.to_json))
      Krikri::AsyncJobs.write_status(jid_b, JSON.parse({"finished" => 1}.to_json))
      File.write("#{Krikri::AsyncJobs.status_path(jid_a)}.tmp", "partial")

      removed = Krikri::AsyncJobs.cleanup_all
      expect((removed) >= (3)).must_equal(true)
      Dir.exists?(Krikri::AsyncJobs.dir).must_equal(true)
      File.exists?(Krikri::AsyncJobs.status_path(jid_a)).must_equal(false)
      File.exists?(Krikri::AsyncJobs.status_path(jid_b)).must_equal(false)
    end
  end

  it "round-trips a status write/read and reports finished? correctly" do
    in_temp_async_dir do
      jid = Krikri::AsyncJobs.generate_jid

      Krikri::AsyncJobs.write_status(jid, JSON.parse({"started" => 1, "finished" => 0}.to_json))
      status = (Krikri::AsyncJobs.read_status(jid) || raise "unexpected nil")
      Krikri::AsyncJobs.finished?(status).must_equal(false)

      Krikri::AsyncJobs.write_status(jid, JSON.parse({"finished" => 1, "changed" => true}.to_json))
      status = (Krikri::AsyncJobs.read_status(jid) || raise "unexpected nil")
      Krikri::AsyncJobs.finished?(status).must_equal(true)
      status["changed"].as_bool.must_equal(true)
    end
  end

  # Regression: the async config carries the FULL module params (secrets
  # included), so it must be 0600 from the moment of creation - a
  # create-then-chmod leaves a window where the file sits umask-default
  # (typically 0644) with the payload already on disk. Checked
  # immediately after the write call returns; the chmod-before-write
  # ordering inside the open block is what guarantees no wider mode ever
  # held the payload (verified by code reading - the window between
  # create and chmod holds an empty file, which a race can't leak).
  it "writes the config file 0600 with the payload intact" do
    in_temp_async_dir do
      jid = Krikri::AsyncJobs.generate_jid
      Krikri::AsyncJobs.write_config(jid, %({"login_password": "s3cret"}))
      (File.info(Krikri::AsyncJobs.config_path(jid)).permissions.value & 0o777).must_equal(0o600)
      File.read(Krikri::AsyncJobs.config_path(jid)).must_equal(%({"login_password": "s3cret"}))
    end
  end

  # Regression: the async dir used to be fixed at require time, so a spec
  # sweeping it hit the developer's real ~/.ansible_async. It must now be
  # resolved at call time from ANSIBLE_ASYNC_DIR (Ansible's own shell
  # plugin env name, confirmed via `ansible-doc -t shell sh`).
  it "resolves status/config paths under ANSIBLE_ASYNC_DIR when set" do
    in_temp_async_dir do |dir|
      jid = Krikri::AsyncJobs.generate_jid
      Krikri::AsyncJobs.status_path(jid).must_equal(File.join(dir, jid))
      Krikri::AsyncJobs.config_path(jid).must_equal(File.join(dir, "#{jid}.config.json"))

      Krikri::AsyncJobs.write_status(jid, JSON.parse({"finished" => 1}.to_json))
      File.exists?(File.join(dir, jid)).must_equal(true)

      Krikri::AsyncJobs.write_config(jid, "{}")
      File.exists?(File.join(dir, "#{jid}.config.json")).must_equal(true)

      Krikri::AsyncJobs.cleanup_all
      Dir.children(dir).must_equal([] of String)
    end
  end

  it "resolves status paths under the HOME default when ANSIBLE_ASYNC_DIR is unset" do
    original = ENV["ANSIBLE_ASYNC_DIR"]?
    original_home = ENV["HOME"]?
    home = File.join(Dir.tempdir, "krikri-async-jobs-spec-home-#{Random::Secure.hex(4)}")
    ENV.delete("ANSIBLE_ASYNC_DIR")
    ENV["HOME"] = home
    begin
      jid = Krikri::AsyncJobs.generate_jid
      expected = File.join(home, ".ansible_async")
      Krikri::AsyncJobs.dir.must_equal(expected)
      Krikri::AsyncJobs.status_path(jid).must_equal(File.join(expected, jid))
      Krikri::AsyncJobs.config_path(jid).must_equal(File.join(expected, "#{jid}.config.json"))
    ensure
      original ? (ENV["ANSIBLE_ASYNC_DIR"] = original) : ENV.delete("ANSIBLE_ASYNC_DIR")
      original_home ? (ENV["HOME"] = original_home) : ENV.delete("HOME")
      FileUtils.rm_rf(home)
    end
  end

  it "expands a leading ~ in ANSIBLE_ASYNC_DIR against HOME" do
    original = ENV["ANSIBLE_ASYNC_DIR"]?
    original_home = ENV["HOME"]?
    home = File.join(Dir.tempdir, "krikri-async-jobs-spec-home-#{Random::Secure.hex(4)}")
    ENV["HOME"] = home
    ENV["ANSIBLE_ASYNC_DIR"] = "~/async-jobs-custom"
    begin
      Krikri::AsyncJobs.dir.must_equal(File.join(home, "async-jobs-custom"))
      ENV["ANSIBLE_ASYNC_DIR"] = "~"
      Krikri::AsyncJobs.dir.must_equal(home)
    ensure
      original ? (ENV["ANSIBLE_ASYNC_DIR"] = original) : ENV.delete("ANSIBLE_ASYNC_DIR")
      original_home ? (ENV["HOME"] = original_home) : ENV.delete("HOME")
      FileUtils.rm_rf(home)
    end
  end

  it "falls back to the HOME default when ANSIBLE_ASYNC_DIR is set but empty" do
    original = ENV["ANSIBLE_ASYNC_DIR"]?
    original_home = ENV["HOME"]?
    home = File.join(Dir.tempdir, "krikri-async-jobs-spec-home-#{Random::Secure.hex(4)}")
    ENV["HOME"] = home
    ENV["ANSIBLE_ASYNC_DIR"] = ""
    begin
      Krikri::AsyncJobs.dir.must_equal(File.join(home, ".ansible_async"))
    ensure
      original ? (ENV["ANSIBLE_ASYNC_DIR"] = original) : ENV.delete("ANSIBLE_ASYNC_DIR")
      original_home ? (ENV["HOME"] = original_home) : ENV.delete("HOME")
      FileUtils.rm_rf(home)
    end
  end
end
