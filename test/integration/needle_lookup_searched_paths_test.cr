require "../minitest_helper"

# ansible-core 2.19.11's controller-side relative-src lookups
# (live-verified in the krikri repo's output-parity sweep sweep10/000044 +
# 000047 and dedicated probe playbooks):
#
# - template's newline_sequence validation message carries REAL control
#   characters (the Python source literal "\n, \r or \r\n") and Ansible's
#   error pipeline strips the trailing " \r\n" - the displayed and fatal
#   text both end at "or". The failure is a bare AnsibleActionFail (no
#   exception context), so the [ERROR] block is the single COLLAPSED
#   segment - no "Task failed." middle, no "<<< caused by >>>".
# - a RELATIVE src that exists nowhere fails with
#   "Could not find or access '<src>'\nSearched in:\n\t..." - the
#   searched list is the task's search stack plus the playbook basedir
#   (two entries per path, templates/ first), and the " on the Ansible
#   Controller." tail lands after the LAST searched path. An absolute
#   src builds no list at all.
# - the same not-found text backs copy: (with the
#   "Unexpected AnsibleActionFail error: " prefix under -c local),
#   script: (no prefix, two-segment block) and unarchive: ("Task failed:
#   " prefix, collapsed block).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("needle-lookup", ".yml")
  File.write(playbook, yaml)
  playbook_dir = File.dirname(playbook)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s, playbook_dir}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "template controller-side src/newline_sequence parity" do
  it "fails a wrong newline_sequence with Ansible's control-character message" do
    status, output, _ = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: t newline
            template:
              src: /nonexistent/needle.j2
              dest: /tmp/needle-out.cfg
              newline_sequence: 15
            ignore_errors: true
      YAML

    status.success?.must_equal(true)
    # Ansible's bytes: literal LF after "one of: ", literal CR after ", "
    output.must_include("Task failed: newline_sequence needs to be one of: \n, \r or\nOrigin: ")
    output.must_include("{\"changed\": false, \"msg\": \"newline_sequence needs to be one of: \\n, \\r or\"}")
    # collapsed block: no caused-by chain for this failure class
    output.wont_include("<<< caused by >>>")
    output.wont_include("Task failed.")
  end

  it "reports Ansible's searched-paths list for a missing relative src" do
    status, output, dir = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: t rel miss
            template:
              src: 68
              dest: /tmp/needle-out.cfg
            ignore_errors: true
      YAML

    status.success?.must_equal(true)
    searched = "Searched in:\n\t#{dir}/templates/68\n\t#{dir}/68\n\t#{dir}/templates/68\n\t#{dir}/68 on the Ansible Controller."
    output.must_include(searched)
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Could not find or access '68'\\nSearched in:")
    # the find_needle failure re-raises inside except: two-segment block
    output.must_include("<<< caused by >>>")
  end

  it "reports no searched-paths list for a missing absolute src" do
    status, output, _ = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: t abs miss
            template:
              src: /nonexistent/needle.j2
              dest: /tmp/needle-out.cfg
            ignore_errors: true
      YAML

    status.success?.must_equal(true)
    output.must_include("Could not find or access '/nonexistent/needle.j2' on the Ansible Controller.")
    output.wont_include("Searched in:")
  end
end

describe "copy/script/unarchive controller-side src miss parity" do
  it "gives copy's local-connection miss the Unexpected-prefix searched list" do
    status, output, dir = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: c rel miss
            copy:
              src: missing_file.txt
              dest: /tmp/needle-out.cfg
            ignore_errors: true
      YAML

    status.success?.must_equal(true)
    output.must_include("Unexpected AnsibleActionFail error: Could not find or access 'missing_file.txt'\nSearched in:\n\t#{dir}/files/missing_file.txt\n\t#{dir}/missing_file.txt\n\t#{dir}/files/missing_file.txt\n\t#{dir}/missing_file.txt on the Ansible Controller.")
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Unexpected AnsibleActionFail error: Could not find or access 'missing_file.txt'\\nSearched in:")
  end

  it "fails a missing relative script src on the controller with Ansible's wording" do
    status, output, dir = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: s rel miss
            script:
              cmd: 68.sh
            ignore_errors: true
      YAML

    status.success?.must_equal(true)
    output.must_include("Task failed: Could not find or access '68.sh'\nSearched in:\n\t#{dir}/files/68.sh\n\t#{dir}/68.sh\n\t#{dir}/files/68.sh\n\t#{dir}/68.sh on the Ansible Controller.")
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Could not find or access '68.sh'\\nSearched in:")
    output.must_include("<<< caused by >>>")
    output.wont_include("does not exist on the target")
  end

  it "gives unarchive's miss the Task-failed prefixed searched list" do
    status, output, dir = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: u rel miss
            unarchive:
              src: 68.tar.gz
              dest: /tmp/needle-out
            ignore_errors: true
      YAML

    status.success?.must_equal(true)
    output.must_include("Task failed: Could not find or access '68.tar.gz'\nSearched in:\n\t#{dir}/files/68.tar.gz\n\t#{dir}/68.tar.gz\n\t#{dir}/files/68.tar.gz\n\t#{dir}/68.tar.gz on the Ansible Controller.")
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: Could not find or access '68.tar.gz'\\nSearched in:")
    # collapsed: no caused-by chain
    output.wont_include("<<< caused by >>>")
  end
end
