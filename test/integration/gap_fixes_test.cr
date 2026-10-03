require "../minitest_helper"

# Regressions for KNOWN divergences from real ansible-core 2.19.11, each
# live-verified by running REAL `ansible-playbook` and krikri-playbook
# directly on a small local play and comparing the registered
# `{{ r | to_json }}` dump (and, where noted, the console output):
#
#   pause    - registered shape is changed, rc, stderr, stdout, start,
#              stop, delta, echo, user_input, failed - no
#              stdout_lines/stderr_lines (real's pause module does not
#              derive them; they are command-family additions).
#   find     - an unreadable directory is recorded in skipped_paths with
#              Python's OSError text, silently (no warning, msg
#              unchanged); a not-a-directory path warns and flips msg.
#   package_facts - registered keys are exactly ansible_facts, failed,
#              changed - no msg.
#   uri      - a file:// url crashes real's module at
#              `int(resp['status'])` (no HTTP status on the response):
#              registered shape is failed, changed, exception, msg with
#              that int() TypeError text and no url/status/elapsed/
#              redirected; a request failure (connection refused) keeps
#              the full shape but in real's fail_json key order.
#   until    - the registered result of an until: task carries an
#              attempts int (the successful 1-based attempt, or the
#              retries value when the loop runs out) and an exhausted
#              loop marks the result failed: true; each failed attempt
#              prints real's "FAILED - RETRYING" line.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Runs a play whose registered `r` is copied through `{{ r | to_json }}`
# into a file (avoiding the display layer's escaping) and returns both
# the parsed dump and the full console output.
private def run_registered_dump(tasks : String) : {JSON::Any, String}
  dump = PluginSpecHelper.tmp_path("gap-fixes-dump-#{Random::Secure.hex(4)}.json")
  playbook = File.tempname("gap-fixes", ".yml")
  File.write(playbook, <<-YAML)
    - hosts: localhost
      gather_facts: false
      connection: local
      tasks:
    #{tasks.lines.map { |line| "    " + line }.join("\n")}
        - name: dump
          ansible.builtin.copy:
            content: |-
              {{ r | to_json }}
            dest: #{dump}
    YAML
  output = IO::Memory.new
  # Warnings go to stderr; capture it too so output checks see the full
  # console text.
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], input: Process::Redirect::Close, output: output, error: output)
  status.success?.must_equal(true)
  {JSON.parse(File.read(dump)), output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "pause registered result shape" do
  it "registers real's key order with no stdout_lines/stderr_lines" do
    result, _output = run_registered_dump(<<-T)
      - ansible.builtin.pause:
          seconds: 1
        register: r
      T
    result.as_h.keys.must_equal(["changed", "rc", "stderr", "stdout", "start", "stop", "delta", "echo", "user_input", "failed"])
    result["rc"].as_i.must_equal(0)
    result["echo"].as_bool.must_equal(true)
    result["user_input"].as_s.must_equal("")
    result["stdout"].as_s.must_match(/^Paused for \d+(\.\d+)? seconds$/)
    result["failed"].as_bool.must_equal(false)
  end
end

describe "find unreadable path handling" do
  it "records a chmod-000 directory in skipped_paths silently" do
    # uid 0 walks straight through a 000 directory (no EACCES to record,
    # so real find reports no skipped path either). CI's job container
    # runs as root; the behavior is identical on any non-root host.
    skip "permission-denial path: root can walk a chmod-000 directory" if PluginSpecHelper.running_as_root?
    base = PluginSpecHelper.tmp_path("find-unreadable")
    Dir.mkdir_p(base)
    hidden = File.join(base, "locked")
    Dir.mkdir_p(hidden)
    File.chmod(hidden, 0o000)
    result, output = run_registered_dump(<<-T)
      - ansible.builtin.find:
          paths: #{hidden}
        register: r
      T
    File.chmod(hidden, 0o755)
    result["skipped_paths"].as_h.keys.must_equal([hidden])
    result["skipped_paths"][hidden].as_s.must_equal("[Errno 13] Permission denied: '#{hidden}'")
    # Real keeps msg "All paths examined" and carries no warnings key for
    # the os.walk onerror path (live-verified vs 2.19.11).
    result["msg"].as_s.must_equal("All paths examined")
    result.as_h.has_key?("warnings").must_equal(false)
    result["files"].as_a.must_equal([] of JSON::Any)
    output.includes?("[WARNING]").must_equal(false)
  ensure
    File.chmod(hidden, 0o755) if hidden && File.exists?(hidden)
  end

  it "warns and flips msg for a not-a-directory path" do
    missing = PluginSpecHelper.tmp_path("find-missing-#{Random::Secure.hex(4)}")
    result, output = run_registered_dump(<<-T)
      - ansible.builtin.find:
          paths: #{missing}
        register: r
      T
    result["skipped_paths"][missing].as_s.must_equal("'#{missing}' is not a directory")
    result["msg"].as_s.must_equal("Not all paths examined, check warnings for details")
    result["warnings"].as_a.size.must_equal(1)
    result["warnings"].as_a.first.as_s.must_equal("Skipped '#{missing}' path due to this access issue: '#{missing}' is not a directory\n")
    output.includes?("Skipped '#{missing}' path due to this access issue").must_equal(true)
  end
end

describe "package_facts registered shape" do
  it "registers exactly ansible_facts, failed, changed with no msg" do
    result, _output = run_registered_dump(<<-T)
      - ansible.builtin.package_facts:
        register: r
      T
    result.as_h.keys.must_equal(["ansible_facts", "failed", "changed"])
  end
end

describe "uri failure shapes" do
  it "registers real's module-crash shape for a file:// url" do
    result, _output = run_registered_dump(<<-T)
      - ansible.builtin.uri:
          url: file:///etc/hostname
        register: r
        ignore_errors: true
      T
    result.as_h.keys.must_equal(["failed", "changed", "exception", "msg"])
    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["exception"].as_s.must_equal("(traceback unavailable)")
    result["msg"].as_s.must_equal("Task failed: Module failed: int() argument must be a string, a bytes-like object or a real number, not 'NoneType'")
  end

  it "keeps the full failure shape in real's fail_json key order for a refused connection" do
    result, _output = run_registered_dump(<<-T)
      - ansible.builtin.uri:
          url: http://127.0.0.1:1/
        register: r
        ignore_errors: true
      T
    result.as_h.keys.must_equal(["redirected", "url", "status", "elapsed", "changed", "failed", "msg", "exception"])
    result["status"].as_i.must_equal(-1)
    result["redirected"].as_bool.must_equal(false)
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_match(/^Status code was -1 and not \[200\]: Request failed: /)
  end
end

describe "until retries attempts key" do
  it "registers attempts 1 on a first-try success, after failed" do
    result, _output = run_registered_dump(<<-T)
      - ansible.builtin.command: /bin/true
        register: r
        until: r.rc == 0
        retries: 2
        delay: 0
      T
    result["attempts"].as_i.must_equal(1)
    result.as_h.keys.last.must_equal("attempts")
    result["failed"].as_bool.must_equal(false)
  end

  it "marks an exhausted loop failed with attempts equal to retries and prints the retrying lines" do
    result, output = run_registered_dump(<<-T)
      - ansible.builtin.command: /bin/true
        register: r
        until: false
        retries: 2
        delay: 0
        ignore_errors: true
      T
    result["attempts"].as_i.must_equal(2)
    result["failed"].as_bool.must_equal(true)
    # Real also projects the error-event exception onto the exhausted
    # result, after attempts (live-verified vs 2.19.11, ignored or not).
    result.as_h.keys.last(3).must_equal(["failed", "attempts", "exception"])
    result["exception"].as_s.must_equal("(traceback unavailable)")
    output.matches?(/FAILED - RETRYING: \[localhost\]: .* \(2 retries left\)\./).must_equal(true)
    output.matches?(/FAILED - RETRYING: \[localhost\]: .* \(1 retries left\)\./).must_equal(true)
  end

  it "registers no attempts key at all for a retries-0 until task" do
    result, _output = run_registered_dump(<<-T)
      - ansible.builtin.command: /bin/true
        register: r
        until: false
        retries: 0
        ignore_errors: true
      T
    result.as_h.has_key?("attempts").must_equal(false)
  end
end
