require "../spec_helper"
require "../../src/krikri/async_jobs"

describe Krikri::AsyncJobs do
  it "generates unique job ids" do
    jids = Array.new(20) { Krikri::AsyncJobs.generate_jid }
    jids.uniq.size.should eq(20)
  end

  it "returns nil for a job that was never written" do
    Krikri::AsyncJobs.read_status("no-such-job-#{Krikri::AsyncJobs.generate_jid}").should be_nil
  end

  it "cleanup removes one job's status and config files" do
    jid = Krikri::AsyncJobs.generate_jid
    begin
      Krikri::AsyncJobs.write_status(jid, JSON.parse({"finished" => 1}.to_json))
      File.write(Krikri::AsyncJobs.config_path(jid), "{}")

      Krikri::AsyncJobs.cleanup(jid).should be_true
      File.exists?(Krikri::AsyncJobs.status_path(jid)).should be_false
      File.exists?(Krikri::AsyncJobs.config_path(jid)).should be_false
      # Second cleanup finds nothing - reports false, no error.
      Krikri::AsyncJobs.cleanup(jid).should be_false
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
      removed.should be >= 3
      Dir.exists?(Krikri::AsyncJobs::DIR).should be_true
      File.exists?(Krikri::AsyncJobs.status_path(jid_a)).should be_false
      File.exists?(Krikri::AsyncJobs.status_path(jid_b)).should be_false
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
      Krikri::AsyncJobs.finished?(status).should be_false

      Krikri::AsyncJobs.write_status(jid, JSON.parse({"finished" => 1, "changed" => true}.to_json))
      status = (Krikri::AsyncJobs.read_status(jid) || raise "unexpected nil")
      Krikri::AsyncJobs.finished?(status).should be_true
      status["changed"].as_bool.should be_true
    ensure
      File.delete?(Krikri::AsyncJobs.status_path(jid))
      File.delete?("#{Krikri::AsyncJobs.status_path(jid)}.tmp")
    end
  end
end
