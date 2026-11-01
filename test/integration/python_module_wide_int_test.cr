require "../minitest_helper"
require "file_utils"

# Integers wider than Int64 from a role-private Python module (issue
# #695): the py_module path parses the module's result bigint-aware and
# the args it ships back INTO the module unquote the marker, so a
# container param keeps its wide int as a real Python int.
#
# Live-verified against ansible-playbook 2.19.11 with the same role
# (library/bigmod.py returning 2**200, -(2**70) and a nested dict):
# `debug: var=r.wide` prints `r.wide:
# 1606938044258990275541962092341162602522202993782792835301376`
# (unquoted), `{{ r.wide | type_debug }}` prints int,
# `{{ r.wide > 18446744073709551616 }}` is True, and with
# `bigmod: d: "{{ r.nested }}"` (argument_spec type raw) the module sees
# `arg_type_n int`, `arg_echo 1267650600228229401496703205377` and
# `str 123456789012345678901234567890`.
#
# The bare whole-span arg case (`n: "{{ r.wide }}"`) is the second `it`
# below: the substituted param text is bare digits by the time
# typed_value sees it - indistinguishable from a quoted wide-digit
# literal, exactly like the small-int case where a quoted "5" and
# `{{ int_var }}` both ship typed - so the digits ride the bigint
# sentinel and the module receives a real int (ansible: n_type int).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "role-private python module returning integers wider than Int64" do
  it "carries the module's wide ints out unquoted and round-trips them through a container arg" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    root = File.tempname("py-module-bigint")
    Dir.mkdir_p(File.join(root, "roles", "bigmod", "library"))
    Dir.mkdir_p(File.join(root, "roles", "bigmod", "tasks"))

    File.write(File.join(root, "roles", "bigmod", "library", "bigmod.py"), <<-PYTHON)
      #!/usr/bin/python
      from ansible.module_utils.basic import AnsibleModule

      module = AnsibleModule(argument_spec={'d': {'type': 'raw'}})
      out = {"wide": 2 ** 200, "neg": -(2 ** 70),
             "nested": {"n": 2 ** 100, "l": [2 ** 70], "s": "123456789012345678901234567890"}}
      if module.params.get('d') is not None:
          d = module.params['d']
          out['arg_type_n'] = type(d['n']).__name__
          out['arg_echo'] = d['n'] + 1
          out['arg_str'] = d['s']
      module.exit_json(changed=False, **out)
      PYTHON
    written = File.join(root, "dump.json")
    File.write(File.join(root, "roles", "bigmod", "tasks", "main.yml"), <<-YAML)
      - bigmod:
        register: r
      - debug:
          var: r.wide
      - debug:
          var: r.neg
      - debug:
          msg: "{{ r.wide | type_debug }}"
      - debug:
          msg: "RUN {{ r.wide > 18446744073709551616 }}"
      - debug:
          msg: "RUN when r.wide >= 18446744073709551616"
        when: "r.wide >= 18446744073709551616"
      - bigmod:
          d: "{{ r.nested }}"
        register: r2
      - debug:
          msg: "arg_type_n {{ r2.arg_type_n }} echo {{ r2.arg_echo }} str {{ r2.arg_str }}"
      - copy:
          content: "{{ {'w': r.wide, 'nested': r.nested} | to_json }}\\n"
          dest: #{written}
      YAML
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - bigmod
      YAML

    captured = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: captured, error: captured, chdir: root)
    output = captured.to_s

    big = (BigInt.new(2) ** 200).to_s
    neg = (-(BigInt.new(2) ** 70)).to_s
    two_pow_100 = (BigInt.new(2) ** 100).to_s
    two_pow_70 = (BigInt.new(2) ** 70).to_s

    status.success?.must_equal(true, output)
    output.includes?("\u{E000}").must_equal(false, "sentinel marker leaked into output:\n#{output}")
    # debug: var= prints the int unquoted.
    output.must_include(%("r.wide": #{big}))
    output.must_include(%("r.neg": #{neg}))
    # type_debug says int.
    output.must_include(%("msg": "int"))
    # comparisons ran against the numbers.
    output.must_include(%("msg": "RUN True"))
    output.must_include("RUN when r.wide >= 18446744073709551616")
    # Round-trip: the container arg reached the module as a real dict
    # with a real int member (ansible prints arg_type_n int ...).
    output.must_include("arg_type_n int echo #{(BigInt.new(2) ** 100) + 1} str 123456789012345678901234567890")
    # to_json: bare digits for the ints, the lookalike string stays quoted.
    dumped = File.read(written)
    dumped.includes?("\u{E000}").must_equal(false, "sentinel marker leaked into to_json output")
    dumped.must_include(%("w": #{big}))
    dumped.must_include(%("n": #{two_pow_100}))
    dumped.must_include(%("l": [#{two_pow_70}]))
    dumped.must_include(%("s": "123456789012345678901234567890"))
  ensure
    FileUtils.rm_rf(root) if root
  end

  # Bare whole-span args and the other wide-int consumers, live-verified
  # against ansible-playbook 2.19.11 with the same role (the scratchpad
  # fixture): `bigmod: n: "{{ b }}"` makes the module see an int
  # (n_type int, n printed unquoted), `bigact: v: "{{ b }}"` makes the
  # action plugin see an int (v_type True, v unquoted), and
  # `lookup('bigl', b, 3)` of a plugin returning [2**150, b*2, 6] prints
  # the LIST (ansible's ",".join raises TypeError on the non-string
  # elements) - the comma-joined string leaked the bigint marker.
  it "passes a bare whole-span wide int typed into a module and an action plugin, and keeps a wide lookup result a list" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    root = File.tempname("py-wide-args")
    Dir.mkdir_p(File.join(root, "roles", "widecall", "library"))
    Dir.mkdir_p(File.join(root, "roles", "widecall", "action_plugins"))
    Dir.mkdir_p(File.join(root, "roles", "widecall", "lookup_plugins"))
    Dir.mkdir_p(File.join(root, "roles", "widecall", "filter_plugins"))
    Dir.mkdir_p(File.join(root, "roles", "widecall", "tasks"))

    File.write(File.join(root, "roles", "widecall", "library", "bigmod.py"), <<-PYTHON)
      #!/usr/bin/python
      from ansible.module_utils.basic import AnsibleModule

      module = AnsibleModule(argument_spec={'n': {'type': 'raw'}})
      n = module.params.get('n')
      module.exit_json(changed=False, n_type=type(n).__name__, n=n)
      PYTHON
    File.write(File.join(root, "roles", "widecall", "action_plugins", "bigact.py"), <<-PYTHON)
      from ansible.plugins.action import ActionBase

      class ActionModule(ActionBase):
          TRANSFERS_FILES = False

          def run(self, tmp=None, task_vars=None):
              result = super(ActionModule, self).run(tmp, task_vars)
              v = self._task.args.get('v')
              result.update(changed=False, big=2 ** 99,
                            v_type=isinstance(v, int), v=v)
              return result
      PYTHON
    File.write(File.join(root, "roles", "widecall", "lookup_plugins", "bigl.py"), <<-PYTHON)
      from ansible.plugins.lookup import LookupBase

      class LookupModule(LookupBase):
          def run(self, terms, variables=None, **kwargs):
              return [2 ** 150] + [t * 2 if isinstance(t, int) else type(t).__name__ for t in terms]
      PYTHON
    File.write(File.join(root, "roles", "widecall", "filter_plugins", "big.py"), <<-PYTHON)
      class FilterModule(object):
          def filters(self):
              return {"big": lambda x: 2 ** 200}
      PYTHON
    File.write(File.join(root, "roles", "widecall", "tasks", "main.yml"), <<-YAML)
      - set_fact:
          b: "{{ 0 | big }}"
      - debug:
          msg: "{{ lookup('bigl', b, 3) }}"
      - debug:
          msg: "RUN {{ lookup('bigl', b, 3) }}"
      - bigmod:
          n: "{{ b }}"
        register: m
      - debug:
          var: m
      - bigact:
          v: "{{ b }}"
        register: a
      - debug:
          var: a
      YAML
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - widecall
      YAML

    captured = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: captured, error: captured, chdir: root)
    output = captured.to_s

    big = (BigInt.new(2) ** 200).to_s
    two_pow_150 = (BigInt.new(2) ** 150).to_s
    two_pow_201 = (BigInt.new(2) ** 201).to_s
    two_pow_99 = (BigInt.new(2) ** 99).to_s

    status.success?.must_equal(true, output)
    # The marker must never leak into any rendered output.
    output.includes?("\u{E000}").must_equal(false, "sentinel marker leaked into output:\n#{output}")
    # lookup(): the list ansible prints, not a comma-joined string.
    output.must_include(%("msg": [\n        #{two_pow_150},\n        #{two_pow_201},\n        6\n    ]))
    # The embedded (hand-rolled evaluator) form renders the same list as
    # Python repr in mixed text, exactly what ansible prints there.
    output.must_include(%("msg": "RUN [#{two_pow_150}, #{two_pow_201}, 6]"))
    # bigmod saw a real int (ansible: n_type int, n unquoted).
    output.must_include(%("n_type": "int"))
    output.must_include(%("n": #{big}))
    # bigact saw a real int too (ansible: v_type True, v unquoted).
    output.must_include(%("v_type": true))
    output.must_include(%("v": #{big}))
    output.must_include(%("big": #{two_pow_99}))
  ensure
    FileUtils.rm_rf(root) if root
  end

  # The round-2 edge cases, each live-verified against ansible-playbook
  # 2.19.11 with the same fixtures (the scratchpad edge.yml):
  # - an EMBEDDED list-kept lookup result renders as Python repr in mixed
  #   text ("X [1, 2] Y"), never the internal JSON-compact form;
  # - an embedded bigl() whose term is a PLAY-VAR carrying a templated
  #   wide int (`vars: b: "{{ 0 | big }}"` - not a set_fact, so the
  #   stored value is still the raw template) reaches the plugin as a
  #   real Python int, and the list reprs with the wide element;
  # - a LITERAL quoted wide-digit string param stays a str (r_type str,
  #   r quoted) while `r: "{{ b }}"` ships a real int and `s: "{{ b }}"`
  #   (type=str) coerces to the digit string - exactly ansible's outputs.
  it "renders embedded list lookups as repr, types templated wide args int, and keeps literal wide digits a str" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    root = File.tempname("py-wide-edge")
    Dir.mkdir_p(File.join(root, "roles", "wideedge", "library"))
    Dir.mkdir_p(File.join(root, "roles", "wideedge", "lookup_plugins"))
    Dir.mkdir_p(File.join(root, "roles", "wideedge", "filter_plugins"))
    Dir.mkdir_p(File.join(root, "roles", "wideedge", "tasks"))

    File.write(File.join(root, "roles", "wideedge", "library", "strmod.py"), <<-PYTHON)
      #!/usr/bin/python
      from ansible.module_utils.basic import AnsibleModule

      module = AnsibleModule(argument_spec={'r': {'type': 'raw'}, 's': {'type': 'str'}})
      module.exit_json(changed=False, r=module.params['r'],
                       r_type=type(module.params['r']).__name__, s=module.params['s'])
      PYTHON
    File.write(File.join(root, "roles", "wideedge", "lookup_plugins", "bigl.py"), <<-PYTHON)
      from ansible.plugins.lookup import LookupBase

      class LookupModule(LookupBase):
          def run(self, terms, variables=None, **kwargs):
              return [2 ** 150] + [t * 2 if isinstance(t, int) else type(t).__name__ for t in terms]
      PYTHON
    File.write(File.join(root, "roles", "wideedge", "filter_plugins", "big.py"), <<-PYTHON)
      class FilterModule(object):
          def filters(self):
              return {"big": lambda x: 2 ** 200}
      PYTHON
    File.write(File.join(root, "roles", "wideedge", "tasks", "main.yml"), <<-YAML)
      - debug:
          msg: "X {{ lookup('flattened', [1, 2]) }} Y"
      - debug:
          msg: "X {{ lookup('bigl', b) }} Y"
      - strmod:
          r: "123456789012345678901234567890"
          s: "123456789012345678901234567890"
        register: lit
      - debug:
          var: lit
      - strmod:
          r: "{{ b }}"
          s: "{{ b }}"
        register: tmpl
      - debug:
          var: tmpl
      YAML
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          b: "{{ 0 | big }}"
        roles:
          - wideedge
      YAML

    captured = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: captured, error: captured, chdir: root)
    output = captured.to_s

    big = (BigInt.new(2) ** 200).to_s
    two_pow_150 = (BigInt.new(2) ** 150).to_s
    two_pow_201 = (BigInt.new(2) ** 201).to_s

    status.success?.must_equal(true, output)
    # The marker must never leak into any rendered output.
    output.includes?("\u{E000}").must_equal(false, "sentinel marker leaked into output:\n#{output}")
    # ansible (2.19.11) prints exactly these two msg texts.
    output.must_include(%("msg": "X [1, 2] Y"))
    output.must_include(%("msg": "X [#{two_pow_150}, #{two_pow_201}] Y"))
    # The literal wide-digit string param stayed a str, quoted.
    output.must_include(%("r": "123456789012345678901234567890"))
    output.must_include(%("r_type": "str"))
    output.must_include(%("s": "123456789012345678901234567890"))
    # The whole-span wide-int arg shipped a real int (ansible: r_type
    # int, r unquoted), and the type=str arg coerced to the digit string.
    output.must_include(%("r": #{big}))
    output.must_include(%("r_type": "int"))
    output.must_include(%("s": "#{big}"))
  ensure
    FileUtils.rm_rf(root) if root
  end

  # Issue #700, live-verified vs ansible-playbook 2.19.11: a QUOTED literal
  # ("5", "true", "null") reaches a raw-typed module param as a str, while
  # `{{ 5 }}` / `{{ x }}` with an int x stay int.
  it "keeps quoted literal digit/bool/null strings a str while templated ints stay int" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    root = File.tempname("py-quoted-literal")
    Dir.mkdir_p(File.join(root, "roles", "qlit", "library"))
    Dir.mkdir_p(File.join(root, "roles", "qlit", "tasks"))

    File.write(File.join(root, "roles", "qlit", "library", "argmod.py"), <<-PYTHON)
      #!/usr/bin/python
      from ansible.module_utils.basic import AnsibleModule

      module = AnsibleModule(argument_spec={'r': {'type': 'raw'}})
      module.exit_json(changed=False, r=module.params['r'],
                       r_type=type(module.params['r']).__name__)
      PYTHON
    File.write(File.join(root, "roles", "qlit", "tasks", "main.yml"), <<-YAML)
      - argmod:
          r: "5"
        register: lit_int
      - argmod:
          r: "true"
        register: lit_bool
      - argmod:
          r: "null"
        register: lit_null
      - argmod:
          r: "{{ x }}"
        register: tmpl_var
      - argmod:
          r: "{{ 5 }}"
        register: tmpl_expr
      - argmod:
          r: "{{ sv }}"
        register: tmpl_strvar
      - debug:
          msg: "lit_int={{ lit_int.r_type }} lit_bool={{ lit_bool.r_type }} lit_null={{ lit_null.r_type }} tmpl_var={{ tmpl_var.r_type }} tmpl_expr={{ tmpl_expr.r_type }} tmpl_strvar={{ tmpl_strvar.r_type }}"
      YAML
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          x: 5
          sv: "5"
        roles:
          - qlit
      YAML

    captured = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: captured, error: captured, chdir: root)
    output = captured.to_s

    status.success?.must_equal(true, output)
    output.includes?("\u{E000}").must_equal(false, "sentinel marker leaked into output:\n#{output}")
    output.must_include("lit_int=str lit_bool=str lit_null=str tmpl_var=int tmpl_expr=int tmpl_strvar=str")
  ensure
    FileUtils.rm_rf(root) if root
  end
end
