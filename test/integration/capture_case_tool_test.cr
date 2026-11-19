require "../minitest_helper"

# bin/krikri-capture-case is the only sanctioned way to record a corpus case's
# expected.out, so its two guarantees get their own specs: it refuses to record
# anything that did not come from the pinned ansible-core release (a transcript
# from 2.19 or from krikri itself would pin the wrong text), and a successful
# capture writes a `<WORK>`-normalized stdout-then-stderr transcript into the
# case directory.
#
# The tool is built by ./build.sh like every other binary in bin/.
private CAPTURE_CASE_BIN = File.expand_path("../../bin/krikri-capture-case", __DIR__)

private def write_capture_case(dir : String) : Nil
  FileUtils.mkdir_p(dir)
  # The failing task is deliberate: it puts the playbook's own path into the
  # transcript (the [ERROR] block's Origin), which is what proves the scratch
  # directory got normalized.
  File.write(File.join(dir, "playbook.yml"), <<-PLAYBOOK)
    - hosts: localhost
      connection: local
      gather_facts: false
      tasks:
        - name: fail on purpose
          ansible.builtin.fail:
            msg: boom
    PLAYBOOK
  File.write(File.join(dir, "inventory.ini"),
    "[local]\nlocalhost ansible_connection=local ansible_python_interpreter=/usr/bin/python3\n")
end

private def run_capture_case(case_dir : String, env : Hash(String, String?)) : {String, String, Int32}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = Process.run(CAPTURE_CASE_BIN, [case_dir], output: stdout, error: stderr, env: env)
  {stdout.to_s, stderr.to_s, status.exit_code}
end

describe "divergence capture tool" do
  it "prints usage and fails without a case directory" do
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(CAPTURE_CASE_BIN, output: stdout, error: stderr)
    status.exit_code.must_equal(2)
    stdout.to_s.must_include("usage: krikri-capture-case <case-dir>")
  end

  it "refuses to capture when ansible-playbook is not the pinned 2.21.6" do
    dir = PluginSpecHelper.tmp_path("capture-case-wrong-version-#{Random::Secure.hex(4)}")
    write_capture_case(dir)
    # /bin/true answers --version with nothing, so the pin check must refuse -
    # this is the guard that keeps a 2.19 (or krikri) transcript out of the
    # corpus, exercised without needing another ansible installed.
    stdout, stderr, rc = run_capture_case(dir, {
      "ANSIBLE_PLAYBOOK_BIN" => "/bin/true",
      "HOME"                 => File.join(dir, "home"),
    })
    rc.must_equal(2)
    stderr.must_include("expected ansible-core 2.21.6")
    File.exists?(File.join(dir, "expected.out")).must_equal(false)
    stdout.must_equal("")
  end

  it "reports a missing ansible-playbook binary instead of crashing" do
    dir = PluginSpecHelper.tmp_path("capture-case-missing-bin-#{Random::Secure.hex(4)}")
    write_capture_case(dir)
    stdout, stderr, rc = run_capture_case(dir, {
      "ANSIBLE_PLAYBOOK_BIN" => File.join(dir, "no-such-ansible-playbook"),
      "HOME"                 => File.join(dir, "home"),
    })
    rc.must_equal(2)
    stderr.must_include("cannot run")
    stdout.must_equal("")
    File.exists?(File.join(dir, "expected.out")).must_equal(false)
  end

  it "captures a normalized transcript from the pinned real ansible" do
    dir = PluginSpecHelper.tmp_path("capture-case-real-#{Random::Secure.hex(4)}")
    write_capture_case(dir)
    stdout, stderr, rc = run_capture_case(dir, {"HOME" => File.join(dir, "home")})

    unless rc == 0
      message = "#{stdout}#{stderr}"
      if message.includes?("expected ansible-core 2.21.6") ||
         message.includes?("could not locate the ansible package tree")
        skip("ansible-core 2.21.6 is not available on this machine")
      end
      flunk("krikri-capture-case failed (#{rc}): #{message}")
    end

    expected_path = File.join(dir, "expected.out")
    File.exists?(expected_path).must_equal(true)
    transcript = File.read(expected_path)

    stdout.must_include("captured #{expected_path}")
    transcript.must_include("PLAY [localhost] ***")
    transcript.must_include("[ERROR]: Task failed: Action failed: boom")
    transcript.must_include("Origin: <WORK>/playbook.yml:5:7")
    # The scratch directory is normalized and nothing under it leaks: the
    # capture ran in a throwaway copy, not in the case directory itself.
    transcript.includes?(dir).must_equal(false)
    transcript.includes?("<WORK>").must_equal(true)
    transcript.includes?("krikri-divergence-capture-").must_equal(false)
  end
end
