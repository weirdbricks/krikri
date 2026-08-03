require "../spec_helper"
require "../../src/crystal_play/async_jobs"

describe CrystalPlay::AsyncJobs do
  it "generates unique job ids" do
    jids = Array.new(20) { CrystalPlay::AsyncJobs.generate_jid }
    jids.uniq.size.should eq(20)
  end

  it "returns nil for a job that was never written" do
    CrystalPlay::AsyncJobs.read_status("no-such-job-#{CrystalPlay::AsyncJobs.generate_jid}").should be_nil
  end

  it "round-trips a status write/read and reports finished? correctly" do
    jid = CrystalPlay::AsyncJobs.generate_jid

    begin
      CrystalPlay::AsyncJobs.write_status(jid, JSON.parse({"started" => 1, "finished" => 0}.to_json))
      status = CrystalPlay::AsyncJobs.read_status(jid).not_nil!
      CrystalPlay::AsyncJobs.finished?(status).should be_false

      CrystalPlay::AsyncJobs.write_status(jid, JSON.parse({"finished" => 1, "changed" => true}.to_json))
      status = CrystalPlay::AsyncJobs.read_status(jid).not_nil!
      CrystalPlay::AsyncJobs.finished?(status).should be_true
      status["changed"].as_bool.should be_true
    ensure
      File.delete?(CrystalPlay::AsyncJobs.status_path(jid))
      File.delete?("#{CrystalPlay::AsyncJobs.status_path(jid)}.tmp")
    end
  end
end
