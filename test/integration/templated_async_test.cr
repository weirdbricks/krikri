require "../minitest_helper"

# Regression for issue #41: a templated `async:` (async: "{{ n }}") was
# parsed with String#to_i? at parse time, which yields nil for a template
# string, so the executor saw "no async" and ran the task synchronously -
# the ASYNC POLL / ASYNC OK lines ansible prints for every async task
# never appeared. ansible resolves async:/poll: per host at execution
# time, after templating, and that is what the executor now does with the
# raw text the parser keeps.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(body : String) : {Process::Status, String}
  # The async job files go under $HOME/.ansible_async, which is host-wide
  # on the dev box; a per-test HOME keeps concurrent minitest workers from
  # touching each other's jobs.
  home = PluginSpecHelper.tmp_path("home")
  Dir.mkdir_p(home)
  playbook = File.tempname("templated-async", ".yml")
  File.write(playbook, body)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, env: {"HOME" => home})
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "templated async:/poll: resolved at execution time" do
  it "runs a templated async: in the background and prints ASYNC POLL/OK" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          n: 30
        tasks:
          - name: async with a templated timeout
            ansible.builtin.command: /bin/sleep 2
            async: "{{ n }}"
            poll: 1
            register: r
          - name: show result
            ansible.builtin.debug:
              msg: "finished={{ r.finished }}"
      YAML

    status.success?.must_equal(true, output)
    # poll: 1 against a ~2s sleep means the poll loop must find the job
    # unfinished at least once before it finishes - the same shape the
    # literal-async fixture asserts.
    output.must_match(/ASYNC POLL on localhost: jid=\S+ started=True finished=False/)
    output.must_match(/ASYNC OK on localhost: jid=\S+/)
    output.must_include("finished=True")
  end

  it "resolves a templated poll: when async: is a literal" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          p: 1
        tasks:
          - name: literal async with a templated poll interval
            ansible.builtin.command: /bin/sleep 2
            async: 30
            poll: "{{ p }}"
            register: r
          - name: show result
            ansible.builtin.debug:
              msg: "finished={{ r.finished }}"
      YAML

    status.success?.must_equal(true, output)
    output.must_match(/ASYNC POLL on localhost: jid=\S+ started=True finished=False/)
    output.must_match(/ASYNC OK on localhost: jid=\S+/)
    output.must_include("finished=True")
  end
end
