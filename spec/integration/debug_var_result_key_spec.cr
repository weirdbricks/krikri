require "../spec_helper"

# Runs the compiled binary against a real playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

# Real Ansible's debug action plugin puts a `var:` result under the
# VARIABLE NAME key - never under msg (podman-diff debug_edge_cases
# D1/D4: a follow-up `d.msg | default('none')` prints 'none' on real
# for both a defined and an undefined var, and an unresolvable var:
# succeeds with the literal string "VARIABLE IS NOT DEFINED!" under
# that same key). A verbosity-skipped debug's registered result
# carries skipped but NO msg key either (D3).
describe "debug: var result key" do
  it "registers a defined var's value under the var name, with no msg" do
    playbook = File.tempname("debug-var-key", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          krikri_spec_defined_var: target-value
        tasks:
          - name: var debug
            ansible.builtin.debug:
              var: krikri_spec_defined_var
            register: r
          - name: show result
            ansible.builtin.debug:
              msg: "R msg={{ r.msg | default('none') }} val={{ r['krikri_spec_defined_var'] | default('none') }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("R msg=none val=target-value")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "registers an undefined var as the VARIABLE IS NOT DEFINED! string and still succeeds" do
    playbook = File.tempname("debug-var-undefined", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: undefined var debug
            ansible.builtin.debug:
              var: krikri_spec_undefined_var_zzz
            register: r
            ignore_errors: true
          - name: show result
            ansible.builtin.debug:
              msg: "R failed={{ r.failed | default('none') }} msg={{ r.msg | default('none') }} val={{ r['krikri_spec_undefined_var_zzz'] | default('none') }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("R failed=False msg=none val=VARIABLE IS NOT DEFINED!")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "registers a verbosity-skipped debug with skipped but no msg" do
    playbook = File.tempname("debug-skip-no-msg", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: gated debug
            ansible.builtin.debug:
              msg: hidden
              verbosity: 3
            register: r
            ignore_errors: true
          - name: show result
            ansible.builtin.debug:
              msg: "R failed={{ r.failed | default('none') }} msg={{ r.msg | default('none') }} skipped={{ r.skipped | default('none') }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("R failed=False msg=none skipped=True")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
