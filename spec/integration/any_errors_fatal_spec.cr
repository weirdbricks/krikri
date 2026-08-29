require "file_utils"
require "../spec_helper"

# any_errors_fatal: and max_fail_percentage: - the play-level "stop the
# rollout" controls. Both were parsed to nothing, so a play written to
# halt the moment a host failed carried right on across the rest of the
# fleet. Expectations from an ansible-core 2.19.4 run over three hosts,
# one of which fails.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")

private def run_play(keywords : String) : {Int32, Array(String)}
  dir = File.tempname("aef")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"),
    "[g]\nh1 ansible_connection=local\nh2 ansible_connection=local\nh3 ansible_connection=local\n")
  File.write(File.join(dir, "pb.yml"), <<-YAML)
    - hosts: all
      gather_facts: false
    #{keywords}
      tasks:
        - name: fail on h2 only
          ansible.builtin.command: /bin/false
          when: inventory_hostname == 'h2'
        - name: later
          ansible.builtin.debug: {msg: "LATER-{{ inventory_hostname }}"}
    YAML

  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"],
    output: stdout_io, error: stdout_io, chdir: dir)
  {status.exit_code, stdout_io.to_s.scan(/LATER-h\d/).map(&.[0]).sort!}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "any_errors_fatal:" do
  # One host failing stops the play for ALL of them - no later task runs
  # anywhere, including on the hosts that were fine.
  it "aborts the play for every host when one fails" do
    code, later = run_play("  any_errors_fatal: true")
    code.should eq(2)
    later.empty?.should be_true
  end

  # Per BATCH: h1's batch completes, h2's fails, h3's never starts.
  it "stops the remaining serial batches too" do
    code, later = run_play("  serial: 1\n  any_errors_fatal: true")
    code.should eq(2)
    later.should eq(["LATER-h1"])
  end
end

describe "max_fail_percentage:" do
  # 1 of 3 hosts = 33.3%, and the comparison is STRICTLY greater.
  it "aborts when the failed share exceeds the limit" do
    run_play("  max_fail_percentage: 20")[1].empty?.should be_true
    run_play("  max_fail_percentage: 33")[1].empty?.should be_true
  end

  it "does not abort when the failed share is within the limit" do
    run_play("  max_fail_percentage: 34")[1].should eq(["LATER-h1", "LATER-h3"])
    run_play("  max_fail_percentage: 100")[1].should eq(["LATER-h1", "LATER-h3"])
  end

  it "aborts on any failure at 0" do
    run_play("  max_fail_percentage: 0")[1].empty?.should be_true
  end
end

describe "neither keyword" do
  # Guard: the default is still "carry on with the hosts that are fine".
  it "leaves the play running for the healthy hosts" do
    code, later = run_play("")
    code.should eq(2)
    later.should eq(["LATER-h1", "LATER-h3"])
  end
end
