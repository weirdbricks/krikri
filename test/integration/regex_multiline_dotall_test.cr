require "../minitest_helper"

# pluggero.openssh (round 981024) divergence: a previously-clean role's
# apt-version scraping regressed once the role piped `apt list --upgradable`
# style output through `regex_search('Version:\ .*:([\d\.]{2,})', '\1',
# multiline=True)`. Real Ansible's multiline kwarg builds Python re.M,
# which only moves ^/$ to line boundaries - `.` must NOT cross newlines
# (that would be re.DOTALL, which these filters never request). krikri
# mapped it to Crystal's Regex::Options::MULTILINE, which implies PCRE
# DOTALL (Ruby semantics): the greedy `.*:` swallowed across the newline
# and the capture landed on the Description body's "compat:1.1.4" instead
# of the Version: line's "8.9".
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

APT_OUTPUT = <<-TEXT
  Package: openssh-server
  Version: 1:8.9p1-3ubuntu0.10
  Homepage: https://www.openssh.com/
  Download-Size: 434 kB
  APT-Sources: http://archive.ubuntu.com/ubuntu jammy-updates/main amd64 Packages
  Description: x
   compat:1.1.4 notes
  TEXT

private def run_repro_playbook : {Process::Status, String, String, String}
  data_file = File.tempname("regex-multiline-repro", ".txt")
  File.write(data_file, APT_OUTPUT)
  playbook = File.tempname("regex-multiline-repro", ".yml")
  File.write(playbook, <<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      tasks:
        - name: Read apt-like output.
          ansible.builtin.command: cat #{data_file}
          register: c
        - name: Extract version facts.
          ansible.builtin.set_fact:
            ver: >-
              {{ (c.stdout | regex_search('Version:\\ .*:([\\d\\.]{2,})', '\\1', multiline=True))[0] }}
            span: >-
              {{ c.stdout | regex_findall('Version:\\ .*compat', multiline=True) | length }}
            anchor: >-
              {{ c.stdout | regex_findall('^ compat:([\\d\\.]+)', multiline=True) | first }}
        - name: Report.
          ansible.builtin.debug:
            msg: "VER={{ ver }} SPAN={{ span }} ANCHOR={{ anchor }}"
    YAML

  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s, data_file, playbook}
ensure
  File.delete(data_file) if data_file && File.exists?(data_file)
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "regex filters: multiline=True is Python re.M, not dotall" do
  it "captures the version on the Version: line, not a later line's colon value" do
    status, output, _, _ = run_repro_playbook
    status.success?.must_equal(true, output)

    # VER: the Version: line's own colon value, NOT the later
    # " compat:1.1.4" line a DOTALL `.*:` would have swallowed into.
    output.must_include("VER=8.9")
    output.wont_include("VER=1.1.4")
    # SPAN: a dot-span crossing the newline must not match under re.M.
    output.must_include("SPAN=0")
    # ANCHOR: re.M's ^ still anchors at line starts.
    output.must_include("ANCHOR=1.1.4")
  end
end
