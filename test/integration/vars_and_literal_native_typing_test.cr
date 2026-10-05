require "../minitest_helper"
require "file_utils"

# ansible-core 2.19's native typing extends beyond the set_fact
# whole-span fix (0.9.1325): it applies to (a) literal YAML scalars in
# set_fact - a quoted `a: "5"` stays the str "5" while `a: 5` is the int 5,
# `a: 0644` is the YAML-1.1 octal int 420, `a: yes` the YAML-1.1 bool true,
# `a: ~` None, and a quoted `"[1, 2]"` stays a string - and (b) whole-span
# template values in `vars:` (play/task vars and include_vars files), where
# `b: "{{ 42 }}"` is a real int and `b: "{{ '42' }}"` a real str.
# Live-verified against ansible-playbook 2.19.11 with the identical
# playbooks.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String, chdir : String? = nil)
  playbook = File.tempname("native-typing", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: chdir)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "YAML literal and vars native typing (2.19 parity)" do
  it "keeps set_fact YAML literal scalars their YAML types" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - set_fact:
              q5: "5"
              n5: 5
              qtrue: "true"
              ntrue: true
              f50: 5.0
              q0644: "0644"
              n0644: 0644
              yyes: yes
              nno: no
              tilde: ~
              qtilde: "~"
              emptyq: ""
              qlist: "[1, 2]"
          - debug:
              msg: "Q5={{ q5 | type_debug }} N5={{ n5 | type_debug }} QTRUE={{ qtrue | type_debug }} NTRUE={{ ntrue | type_debug }} F50={{ f50 | type_debug }} Q0644={{ q0644 | type_debug }} N0644={{ n0644 | type_debug }} N0644V={{ n0644 }} YYES={{ yyes | type_debug }} NNO={{ nno | type_debug }} TILDE={{ tilde | type_debug }} TILDE_NONE={{ tilde is none }} QTILDE={{ qtilde | type_debug }} EMPTYQ={{ emptyq | type_debug }} QLIST={{ qlist | type_debug }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("Q5=str")
    output.must_include("N5=int")
    output.must_include("QTRUE=str")
    output.must_include("NTRUE=bool")
    output.must_include("F50=float")
    output.must_include("Q0644=str")
    output.must_include("N0644=int")
    output.must_include("N0644V=420")
    output.must_include("YYES=bool")
    output.must_include("NNO=bool")
    output.must_include("TILDE=NoneType")
    output.must_include("TILDE_NONE=True")
    output.must_include("QTILDE=str")
    output.must_include("EMPTYQ=str")
    output.must_include("QLIST=str")
  end

  it "keeps free-form set_fact k=v literal values strings and templated values native" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - set_fact: a=5 c=plain
          - set_fact: b={{ 42 }}
          - debug:
              msg: "A={{ a | type_debug }} B={{ b | type_debug }} C={{ c | type_debug }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("A=str")
    output.must_include("B=int")
    output.must_include("C=str")
  end

  it "native-types whole-span vars templates (play vars, task vars, include_vars)" do
    vars_file = File.tempname("native-vars", ".yml")
    File.write(vars_file, "iv_int: \"{{ 42 }}\"\niv_str: \"{{ '42' }}\"\n")
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          p_int: "{{ 42 }}"
          p_str: "{{ '42' }}"
          p_list: "{{ [1, 2] }}"
          p_dict: "{{ {'a': 1} }}"
          p_bool: "{{ true }}"
          p_none: "{{ none }}"
          p_concat: "{{ 4 ~ 2 }}"
        tasks:
          - include_vars: #{vars_file}
          - set_fact:
              t_int: "{{ 42 }}"
              t_str: "{{ '42' }}"
          - debug:
              msg: "PI={{ p_int | type_debug }} PS={{ p_str | type_debug }} PL={{ p_list | type_debug }} PD={{ p_dict | type_debug }} PB={{ p_bool | type_debug }} PN={{ p_none | type_debug }} PN_NONE={{ p_none is none }} PC={{ p_concat | type_debug }} IVI={{ iv_int | type_debug }} IVS={{ iv_str | type_debug }} TI={{ t_int | type_debug }} TS={{ t_str | type_debug }} TSKI={{ task_int | type_debug }} TSKS={{ task_str | type_debug }}"
            vars:
              task_int: "{{ 42 }}"
              task_str: "{{ '42' }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("PI=int")
    output.must_include("PS=str")
    output.must_include("PL=list")
    output.must_include("PD=dict")
    output.must_include("PB=bool")
    output.must_include("PN=NoneType")
    output.must_include("PN_NONE=True")
    output.must_include("PC=str")
    output.must_include("IVI=int")
    output.must_include("IVS=str")
    output.must_include("TI=int")
    output.must_include("TS=str")
    output.must_include("TSKI=int")
    output.must_include("TSKS=str")
  ensure
    File.delete(vars_file) if vars_file && File.exists?(vars_file)
  end

  it "still fails strict-undefined for a vars whole-span template referencing an undefined name" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          v: "{{ not_defined_anywhere }}"
        tasks:
          - debug:
              msg: "value={{ v }}"
      YAML

    status.success?.must_equal(false)
    output.must_include("not_defined_anywhere")
  end

  it "evaluates a whole-span vars expression exactly once (side-effecting lookups)" do
    counter = File.tempname("vars-once", ".txt")
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          x: "{{ lookup('pipe', 'echo run >> #{counter}; wc -l < #{counter}') }}"
        tasks:
          - debug:
              msg: "X={{ x }} T={{ x | type_debug }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("X=1 T=str")
    File.read(counter).lines.size.must_equal(1)
  ensure
    File.delete(counter) if counter && File.exists?(counter)
  end

  it "recovers module behavior: file mode from a templated octal int ({{ 420 }})" do
    # With vars whole-span native typing, `mode: "{{ m_int }}"` where
    # m_int: "{{ 420 }}" now resolves to the int 420, and the executor's
    # int-mode reformat ('%04o') turns it into "0644" - matching real
    # ansible-playbook 2.19.11 (stat reports 644). Before the fix the var
    # resolved to the string "420", which was applied as octal digits.
    path = "/tmp/krikri-vars-native-mode-#{Process.pid}"
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          m_int: "{{ 420 }}"
        tasks:
          - file:
              path: #{path}
              state: touch
              mode: "{{ m_int }}"
          - command: stat -c %a #{path}
            register: m
          - debug:
              msg: "MODE={{ m.stdout }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("MODE=644")
  ensure
    File.delete(path) if path && File.exists?(path)
  end
end
