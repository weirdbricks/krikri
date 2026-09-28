require "../minitest_helper"

# Real ansible-core 2.19's native typing rule (live-verified against
# ansible-playbook 2.19.11): a template whose whole AST is one output node
# (`{{ expr }}`) returns the NATIVE type of the expression - a Jinja string
# expression stays a str even when its text looks like a number ("{{ '8.9' }}"
# is the string "8.9", never the float 8.9); only an expression that actually
# evaluates to a number/bool ("{{ 8.9 }}", "{{ '42' | int }}", a var whose
# value is already one) is numeric. Multi-span/literal-text templates
# ("v{{ x }}") are always str. krikri's set_fact path used to re-coerce the
# substituted STRING by shape - pre-2.19 ANSIBLE_JINJA2_NATIVE=off
# literal_eval behavior, present since the plugin was introduced (0.9.24) -
# so "{{ '8.9' }}" became the float 8.9 and "{{ 'true' }}" the bool true.
# Found via pluggero.openssh (round 981024): its
# `openssh_installed_version != openssh_pkg_mgr_version` guard compared a
# coerced float against the real string, was always true, and reinstalled
# openssh on every run. The fix threads the expression's structurally
# evaluated type across the strings-only param wire (NATIVE_TYPED_PREFIX +
# JSON) and the set_fact plugin decodes it instead of re-coercing.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("set-fact-native", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "set_fact keeps a Jinja string expression a string (2.19 native typing)" do
  it "matches real ansible's type_debug for the full string-vs-native matrix" do
    # Every line below is live-verified against real ansible-playbook
    # 2.19.11 with the identical playbook (str/str/str/str/str/float/int/
    # int/float/str/str/str/str, all comparisons True).
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - set_fact:
              a: "{{ '8.9' }}"
              b: "{{ 'x8.9' | regex_replace('x', '') }}"
              c: "{{ '0644' }}"
              d: "{{ '1e3' }}"
              e: "{{ 'true' }}"
              f: "{{ 8.9 }}"
              g: "{{ 42 }}"
              h: "{{ '42' | int }}"
              i: "{{ '8.9' | float }}"
          - set_fact:
              x: 5
          - set_fact:
              j: "{{ x ~ '' }}"
              k: "v{{ 5 }}"
          - command: echo 8.9
            register: r
          - set_fact:
              l: "{{ r.stdout }}"
              m: "{{ '8.9' | regex_search('8.9') }}"
          - debug:
              msg: "A={{ a | type_debug }} B={{ b | type_debug }} C={{ c | type_debug }} D={{ d | type_debug }} E={{ e | type_debug }} F={{ f | type_debug }} G={{ g | type_debug }} H={{ h | type_debug }} I={{ i | type_debug }} J={{ j | type_debug }} K={{ k | type_debug }} L={{ l | type_debug }} M={{ m | type_debug }} EQA={{ a == '8.9' }} EQB={{ b == '8.9' }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("A=str")
    output.must_include("B=str")
    output.must_include("C=str")
    output.must_include("D=str")
    output.must_include("E=str")
    output.must_include("F=float")
    output.must_include("G=int")
    output.must_include("H=int")
    output.must_include("I=float")
    output.must_include("J=str")
    output.must_include("K=str")
    output.must_include("L=str")
    output.must_include("M=str")
    output.must_include("EQA=True")
    output.must_include("EQB=True")
  end

  it "keeps a numeric-looking string fact string across a second set_fact hop" do
    # The openssh shape itself: the string fact re-referenced from another
    # whole-span template must not pick a numeric type back up downstream.
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - set_fact:
              ver: "{{ '8.9' }}"
          - set_fact:
              ver2: "{{ ver }}"
          - debug:
              msg: "T={{ ver2 | type_debug }} EQ={{ ver2 == '8.9' }} NE={{ ver2 != '8.9' }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("T=str")
    output.must_include("EQ=True")
    output.must_include("NE=False")
  end

  it "still native-types expressions that genuinely evaluate to numbers/bools/containers" do
    # The legitimate native-typing cases the wire fix must not regress:
    # {{ 5 }} -> int, {{ true }} -> bool, a pre-typed int var hop stays
    # int, a container expression stays a real list/dict.
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - set_fact:
              n: 5
          - set_fact:
              i: "{{ 5 }}"
              bo: "{{ true }}"
              hop: "{{ n }}"
              lst: "{{ [1, 2] }}"
              dct: "{{ {'a': 1} }}"
          - debug:
              msg: "I={{ i | type_debug }} BO={{ bo | type_debug }} HOP={{ hop | type_debug }} LST={{ lst | type_debug }} DCT={{ dct | type_debug }} SUM={{ i + 1 }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("I=int")
    output.must_include("BO=bool")
    output.must_include("HOP=int")
    output.must_include("LST=list")
    output.must_include("DCT=dict")
    output.must_include("SUM=6")
  end

  it "keeps a quoted module mode string a string (mode: \"{{ '0644' }}\")" do
    # Module params string-coerce through their own argspec, so a quoted
    # "0644" must reach the module as the string "0644" (octal digits),
    # never the decimal int 420.
    path = PluginSpecHelper.tmp_path("krikri-native-mode")
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - file:
              path: #{path}
              state: touch
              mode: "{{ '0644' }}"
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

  it "evaluates a whole-span expression exactly once (side-effecting lookups)" do
    # The native-type recovery must REPLACE the string substitution, not
    # run in addition to it: evaluating twice ran a pipe lookup twice and
    # stored the second run's output ("2"). Real ansible-playbook 2.19.11
    # runs it once and stores the string "1" (live-verified).
    counter = File.tempname("set-fact-once", ".txt")
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - set_fact:
              x: "{{ lookup('pipe', 'echo run >> #{counter}; wc -l < #{counter}') }}"
          - debug:
              msg: "X={{ x }} T={{ x | type_debug }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("X=1 T=str")
    File.read(counter).lines.size.must_equal(1)
  ensure
    File.delete(counter) if counter && File.exists?(counter)
  end
end
