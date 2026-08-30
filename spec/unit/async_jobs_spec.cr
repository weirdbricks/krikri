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
