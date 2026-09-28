require "../minitest_helper"
require "../../src/krikri/async_jobs"

describe Krikri::AsyncJobs do
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
    Krikri::AsyncJobs.read_status("no-such-job-#{Krikri::AsyncJobs.generate_jid}").must_be_nil
  end

  it "cleanup removes one job's status and config files" do
    jid = Krikri::AsyncJobs.generate_jid
    begin
      Krikri::AsyncJobs.write_status(jid, JSON.parse({"finished" => 1}.to_json))
      File.write(Krikri::AsyncJobs.config_path(jid), "{}")

      Krikri::AsyncJobs.cleanup(jid).must_equal(true)
      File.exists?(Krikri::AsyncJobs.status_path(jid)).must_equal(false)
      File.exists?(Krikri::AsyncJobs.config_path(jid)).must_equal(false)
      # Second cleanup finds nothing - reports false, no error.
      Krikri::AsyncJobs.cleanup(jid).must_equal(false)
    ensure
      File.delete?(Krikri::AsyncJobs.status_path(jid))
      File.delete?(Krikri::AsyncJobs.config_path(jid))
    end
  end

  it "cleanup_all sweeps every job file including stray tmp leftovers" do
    jid_a = Krikri::AsyncJobs.generate_jid
    jid_b = Krikri::AsyncJobs.generate_jid
    begin
      Krikri::AsyncJobs.write_status(jid_a, JSON.parse({"finished" => 1}.to_json))
      Krikri::AsyncJobs.write_status(jid_b, JSON.parse({"finished" => 1}.to_json))
      File.write("#{Krikri::AsyncJobs.status_path(jid_a)}.tmp", "partial")

      removed = Krikri::AsyncJobs.cleanup_all
      expect((removed) >= (3)).must_equal(true)
      Dir.exists?(Krikri::AsyncJobs::DIR).must_equal(true)
      File.exists?(Krikri::AsyncJobs.status_path(jid_a)).must_equal(false)
      File.exists?(Krikri::AsyncJobs.status_path(jid_b)).must_equal(false)
    ensure
      File.delete?(Krikri::AsyncJobs.status_path(jid_a))
      File.delete?(Krikri::AsyncJobs.status_path(jid_b))
      File.delete?("#{Krikri::AsyncJobs.status_path(jid_a)}.tmp")
      File.delete?(Krikri::AsyncJobs.config_path(jid_a))
      File.delete?(Krikri::AsyncJobs.config_path(jid_b))
    end
  end

  it "round-trips a status write/read and reports finished? correctly" do
    jid = Krikri::AsyncJobs.generate_jid

    begin
      Krikri::AsyncJobs.write_status(jid, JSON.parse({"started" => 1, "finished" => 0}.to_json))
      status = (Krikri::AsyncJobs.read_status(jid) || raise "unexpected nil")
      Krikri::AsyncJobs.finished?(status).must_equal(false)

      Krikri::AsyncJobs.write_status(jid, JSON.parse({"finished" => 1, "changed" => true}.to_json))
      status = (Krikri::AsyncJobs.read_status(jid) || raise "unexpected nil")
      Krikri::AsyncJobs.finished?(status).must_equal(true)
      status["changed"].as_bool.must_equal(true)
    ensure
      File.delete?(Krikri::AsyncJobs.status_path(jid))
      File.delete?("#{Krikri::AsyncJobs.status_path(jid)}.tmp")
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
    jid = Krikri::AsyncJobs.generate_jid
    begin
      Krikri::AsyncJobs.write_config(jid, %({"login_password": "s3cret"}))
      (File.info(Krikri::AsyncJobs.config_path(jid)).permissions.value & 0o777).must_equal(0o600)
      File.read(Krikri::AsyncJobs.config_path(jid)).must_equal(%({"login_password": "s3cret"}))
    ensure
      File.delete?(Krikri::AsyncJobs.config_path(jid))
    end
  end
end
