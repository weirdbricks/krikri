require "../minitest_helper"
require "file_utils"
require "../../src/krikri/variable_substitutor/expression_evaluator"
# Pull in the Ansible-specific Crinja filter registrations (to_datetime
# etc.), as template_action_plugin.cr does for every real template-rendering
# binary - without this the ExpressionEvaluator's Crinja env has none of them.
require "../../src/krikri/krikri_jinja_filters"

describe Krikri::VariableSubstitutor::ExpressionEvaluator do
  it "dispatches simple lookups" do
    v = Hash(String, JSON::Any).new
    v["name"] = JSON::Any.new("ada")
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("name").must_equal("ada")
  end

  it "dispatches nested lookups" do
    v = Hash(String, JSON::Any).new
    v["user"] = JSON.parse(%({"name": "ada"}))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("user.name").must_equal("ada")
  end

  it "dispatches indexed access" do
    v = Hash(String, JSON::Any).new
    v["items"] = JSON.parse(%(["a", "b"]))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("items[0]").must_equal("a")
  end

  it "resolves integer character indexing on a STRING through the full evaluator, matching Jinja2/Python str[0]" do
    # Real bug (round 72000 triage, louim.bedrock-site-protect): the
    # ansible_python_version fact was already populated, but its consumer
    # idiom `passlib_package[ansible_python_version[0]]` (and the task
    # name `"...for python {{ ansible_python_version[0] }}"`) still
    # rendered "undefined" - the hand-rolled VariableLookup#index_into
    # handled String indexing fine, but the evaluate_bracket_expr
    # dispatch is Crinja-first, and the vendored Crinja resolved a
    # String integer-subscript to Undefined (its indexable? check no
    # longer recognized String on modern Crystal) without ever falling
    # back. `passlib_package` then keyed on the literal "undefined".
    v = Hash(String, JSON::Any).new
    v["ansible_python_version"] = JSON::Any.new("3.10.12")
    v["passlib_package"] = JSON.parse(%({"3": "python3-passlib", "2": "python-passlib"}))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("ansible_python_version[0]").must_equal("3")
    evaluator.evaluate("ansible_python_version[-1]").must_equal("2")
    evaluator.evaluate("'3.10.12'[0]").must_equal("3")
    evaluator.evaluate("passlib_package[ansible_python_version[0]]").must_equal("python3-passlib")
  end

  it "dispatches comparisons before filters" do
    # Real Python/Jinja2 stringifies a comparison result as "True"/
    # "False" (capitalized), not Crystal's lowercase - verified directly
    # against real Python's own jinja2.Environment.
    v = Hash(String, JSON::Any).new
    v["rc"] = JSON::Any.new(0_i64)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("rc == 0").must_equal("True")
  end

  it "applies a filter to a simple variable" do
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(missing | default('fallback'))).must_equal("fallback")
  end

  it "evaluates a filter combined with a comparison in the same expression" do
    # Real, previously-shipped bug: has_comparison? matched before the `|`
    # check, so `mylist | length > 0` routed entirely to
    # ComparisonEvaluator with the filter chain still attached to the
    # operand text, which it had no way to evaluate - this always
    # returned "false" regardless of the actual list, in *any* {{ }}
    # substitution context (debug: msg:, when:, etc.), not just when:'s
    # own bare-conditional path.
    v = Hash(String, JSON::Any).new
    v["mylist"] = JSON::Any.new([JSON::Any.new("a"), JSON::Any.new("b"), JSON::Any.new("c")])
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("mylist | length > 0").must_equal("True")

    v["mylist"] = JSON::Any.new([] of JSON::Any)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("mylist | length > 0").must_equal("False")
  end

  it "evaluates range(stop) with the | list filter, matching Python's range()" do
    # Real bug found benchmarking a perf playbook: `loop: "{{ range(1, 11)
    # | list }}"` silently resolved to nil (fell through to plain variable
    # lookup on the literal text "range(1, 11)", always undefined),
    # running the loop body once with `item` undefined instead of 10
    # times.
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("range(3) | list").must_equal(%([0,1,2]))
  end

  it "evaluates bare range(stop) with no filter at all" do
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("range(3)").must_equal(%([0,1,2]))
  end

  it "evaluates range(start, stop)" do
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("range(1, 11) | list").must_equal(%([1,2,3,4,5,6,7,8,9,10]))
  end

  it "evaluates range(start, stop, step) including a negative step" do
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("range(0, 10, 2) | list").must_equal(%([0,2,4,6,8]))
    evaluator.evaluate("range(5, 0, -1) | list").must_equal(%([5,4,3,2,1]))
  end

  it "evaluates range() arguments that are themselves variables" do
    v = Hash(String, JSON::Any).new
    v["n"] = JSON::Any.new(4_i64)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("range(1, n) | list").must_equal(%([1,2,3]))
  end

  it "defaults lookup('first_found', ...) with no paths: to the role's ROOT dir, not vars/" do
    # Probed live against ansible-core 2.19.4 (this project's benchmark
    # baseline): the lookup form's no-paths: search stack is the role's
    # ROOT directory first, then role root/tasks, then the play basedir -
    # vars/, files/, and templates/ are NOT searched at all (that
    # per-subdir behavior belongs to the with_first_found: KEYWORD form,
    # which picks its subdir from the task's action name). The role's
    # own vars/Debian.yml here must NOT be found - probed: Ansible
    # returns [] (skip: true) in exactly this fixture. Previously this
    # engine's default roots included "vars" and returned the vars file,
    # which Frzk.chrony's include_tasks then tried to run as a task list.
    role_dir = PluginSpecHelper.tmp_path("first_found_role_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "vars"))
    File.write(File.join(role_dir, "vars", "Debian.yml"), "greeting: hello\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["params"] = JSON.parse(%({"files": ["Debian.yml"], "skip": true}))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('first_found', params)").wont_equal(File.join(role_dir, "vars", "Debian.yml"))
  end

  it "defaults lookup('first_found', ...) with no paths: to the role's tasks/ dir before vars/" do
    # Probed live against ansible-core 2.19.4: role root first, then the
    # role's own tasks/ dir; vars/ is never part of the no-paths: search.
    # ipr-cnrs.glpi_agent's own idiom (`include_tasks: "{{ lookup('
    # first_found', params) }}"` with `params: {files: ['{{
    # ansible_distribution }}.yml']}` and NO `paths:`, from the role's
    # own tasks/main.yml) relies on the tasks/ entry - Ansible
    # resolves its own tasks/Debian.yml there.
    role_dir = PluginSpecHelper.tmp_path("first_found_tasks_default_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    Dir.mkdir_p(File.join(role_dir, "vars"))
    File.write(File.join(role_dir, "tasks", "Debian.yml"), "- debug: {msg: correct}\n")
    File.write(File.join(role_dir, "vars", "Debian.yml"), "wrong_marker: true\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["params"] = JSON.parse(%({"files": ["Debian.yml"]}))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('first_found', params)").must_equal(File.join(role_dir, "tasks", "Debian.yml"))
  end

  it "role ROOT beats role tasks/ in the no-paths: default search" do
    # Probed live against ansible-core 2.19.4: with Debian.yml present at
    # BOTH the role root and role root/tasks, the lookup form returned
    # the ROLE ROOT copy.
    role_dir = PluginSpecHelper.tmp_path("first_found_root_priority_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    File.write(File.join(role_dir, "Debian.yml"), "root copy\n")
    File.write(File.join(role_dir, "tasks", "Debian.yml"), "tasks copy\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["params"] = JSON.parse(%({"files": ["Debian.yml"]}))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('first_found', params)").must_equal(File.join(role_dir, "Debian.yml"))
  end

  it "does NOT search files/ or templates/ in the no-paths: default (only the with_ keyword form does)" do
    # Probed live against ansible-core 2.19.4: a candidate existing ONLY
    # under role root/files/ (or templates/) is NOT found by the lookup
    # form with no paths: (Ansible returned [] with skip: true).
    # The old "files has priority" default root found it here -
    # contradicting Ansible.
    role_dir = PluginSpecHelper.tmp_path("first_found_files_priority_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    Dir.mkdir_p(File.join(role_dir, "files"))
    Dir.mkdir_p(File.join(role_dir, "templates"))
    File.write(File.join(role_dir, "files", "Debian.yml"), "wrong\n")
    File.write(File.join(role_dir, "templates", "Debian.yml"), "wrong\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["params"] = JSON.parse(%({"files": ["Debian.yml"], "skip": true}))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('first_found', params)").wont_equal(File.join(role_dir, "files", "Debian.yml"))
    evaluator.evaluate("lookup('first_found', params)").wont_equal(File.join(role_dir, "templates", "Debian.yml"))
  end

  it "no-paths: default falls back to the play basedir (playbook_dir) after the role roots" do
    # Probed live against ansible-core 2.19.4: a role task whose candidate
    # exists ONLY in the play basedir (the playbook's own directory) IS
    # found - real path_dwim_relative_stack appends basedir as its last
    # resort. Previously the role roots were the whole search and the
    # play-dir file was missed.
    role_dir = PluginSpecHelper.tmp_path("first_found_playdir_spec", "roles", "fallback_role")
    play_dir = PluginSpecHelper.tmp_path("first_found_playdir_spec")
    `rm -rf #{play_dir}`
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    File.write(File.join(play_dir, "Debian.yml"), "play dir copy\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["playbook_dir"] = JSON::Any.new(play_dir)
    v["params"] = JSON.parse(%({"files": ["Debian.yml"]}))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('first_found', params)").must_equal(File.join(play_dir, "Debian.yml"))
  end

  it "accepts a fully-qualified lookup plugin name, not just the bare one" do
    # Real bug found benchmarking several juju4.* roles (bind, cribl,
    # ollama, opkssh, openwebui, ...), which all share this exact idiom:
    # `include_vars: "{{ lookup('ansible.builtin.first_found', params)
    # }}"` - the FQCN spelling, not the bare "first_found" every other
    # first_found spec above uses. evaluate_lookup's `case lookup_type`
    # only ever matched the bare form, so this fell through every branch
    # to the final "undefined" fallback regardless of whether any
    # candidate file actually existed - failing "file not found:
    # undefined" for every one of these roles.
    role_dir = PluginSpecHelper.tmp_path("first_found_fqcn_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "vars"))
    File.write(File.join(role_dir, "Debian.yml"), "greeting: hello\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["params"] = JSON.parse(%({"files": ["Debian.yml"]}))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('ansible.builtin.first_found', params)").must_equal(File.join(role_dir, "Debian.yml"))
  end

  it "accepts a TEMPLATED SCALAR files: value (renders it, does not drop it as an empty list)" do
    # Real bug found benchmarking idiv_biodiversity.systemd_timesyncd
    # (round 74011): the role's own vars/main.yml builds the candidates
    # through a templated scalar - `__vars_files: { files: "{{ candidates
    # | map('regex_replace', '$', '.yml') | list }}", paths: [vars] }` -
    # and the task is `include_vars: "{{ lookup('first_found',
    # __vars_files) }}"`. The params dict deliberately reaches
    # #evaluate_first_found RAW (nested {{ }} intact, first_found_params's
    # own doing), so `files` arrived as the unrendered STRING and the old
    # bare `as_a?` in #lookup_array silently dropped it as an EMPTY
    # candidate list - first_found "found nothing" no matter what files
    # existed, and include_vars: failed "file not found: undefined" where
    # Ansible (verified live against 2.19.4) templates the whole term
    # and finds vars/ubuntu_22.yml.
    role_dir = PluginSpecHelper.tmp_path("first_found_templated_scalar_files_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "vars"))
    File.write(File.join(role_dir, "vars", "ubuntu_22.yml"), "greeting: hello\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["ansible_distribution"] = JSON::Any.new("Ubuntu")
    v["ansible_distribution_major_version"] = JSON::Any.new("22")
    v["candidates"] = JSON.parse(%(["{{ ansible_distribution | lower }}_{{ ansible_distribution_major_version }}", "default"]))
    v["params"] = JSON.parse(%({"files": "{{ candidates | map('regex_replace', '$', '.yml') | list }}", "paths": ["vars"]}))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('first_found', params)").must_equal(File.join(role_dir, "vars", "ubuntu_22.yml"))
  end

  it "raises the Ansible error when first_found finds nothing and skip is not set" do
    # Verified live against ansible-core 2.19.4: a no-match first_found
    # lookup FAILS the task ("The lookup plugin 'first_found' failed: No
    # file was found when using first_found."); the old "undefined"
    # sentinel return leaked that string into the consumer instead
    # (include_vars:'s "file not found: undefined").
    role_dir = PluginSpecHelper.tmp_path("first_found_no_match_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(role_dir)

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["params"] = JSON.parse(%({"files": ["Missing.yml"], "paths": ["vars"]}))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    assert_raises_message(Krikri::FirstFoundLookupError, "No file was found when using first_found") do
      evaluator.evaluate("lookup('first_found', params)")
    end
  end

  it "returns [] when first_found finds nothing with skip: true" do
    # Verified live against ansible-core 2.19.4: `X{{ lookup('first_
    # found', {'files': ['nope.yml'], 'paths': ['vars'], 'skip': true})
    # }}Y` renders "X[]Y" - the old code returned the "undefined" sentinel
    # for the skip case too, so a chained default(...) never fired.
    role_dir = PluginSpecHelper.tmp_path("first_found_skip_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(role_dir)

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["params"] = JSON.parse(%({"files": ["Missing.yml"], "paths": ["vars"], "skip": true}))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('first_found', params)").must_equal("[]")
  end

  it "strictly fails a templated scalar files: whose own expression references an undefined variable" do
    # Ansible templates the lookup's term before the plugin sees it,
    # so an undefined variable inside a templated `files:` scalar fails
    # the calling task - the strict per-entry rendering the literal-list
    # form already had must apply to the scalar form too.
    role_dir = PluginSpecHelper.tmp_path("first_found_scalar_undefined_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(role_dir)

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["params"] = JSON.parse(%({"files": "{{ nope_var }}.yml", "paths": ["vars"]}))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    assert_raises(Krikri::UndefinedVariableError) do
      evaluator.evaluate("lookup('first_found', params)")
    end
  end

  it "resolves lookup('fileglob', ...) to a real (possibly empty) list of matching files" do
    # Real bug found via PowerDNS.pdns's own per-loop-item `when: lookup(
    # 'ansible.builtin.fileglob', role_path ~ '/vars/' ~ item, wantlist=
    # True) | length > 0` guard on an `include_vars:` loop (the standard
    # "generic to specific OS vars file, skip whichever don't exist"
    # idiom) - the FUNCTION-call form of fileglob (distinct from the
    # `map('fileglob')` FILTER form FilterEngine already handled) was
    # entirely unimplemented, falling to the "undefined" string fallback
    # - `"undefined" | length > 0` is true (9 chars), so the guard always
    # ran `include_vars:` even for files that don't exist, failing with
    # "file not found" where Ansible just skips the loop iteration.
    role_dir = PluginSpecHelper.tmp_path("fileglob_lookup_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "vars"))
    File.write(File.join(role_dir, "vars", "Debian.yml"), "greeting: hello\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('ansible.builtin.fileglob', role_path ~ '/vars/Debian.yml') | length")
      .must_equal("1")
    evaluator.evaluate("lookup('ansible.builtin.fileglob', role_path ~ '/vars/Debian-13.yml') | length")
      .must_equal("0")
  end

  it "resolves a RELATIVE fileglob pattern against the role search path, not the process CWD" do
    # Real bug found benchmarking pluggero.common_pkgs and pluggero.
    # user_setup (round 400041/400044, same author): both drive a
    # looped include_tasks through
    # `lookup('ansible.builtin.fileglob', 'tasks/*.yml').split(',')
    # | reject('search', 'main.yml') | reject('search', 'noauto_*')
    # | sort` - a RELATIVE glob pattern. Ansible's fileglob lookup
    # dwims relative patterns against the role search stack (probed
    # live against 2.19.4: 'tasks/*.yml' from a role task finds
    # <role>/tasks/*.yml), but krikri globbed against the process CWD
    # (the playbook's directory), found nothing, and the whole loop
    # collapsed to a single skipped task where Ansible expanded
    # it into the role's per-play task files. Also probed live: an
    # unmatched relative name falls through to the play dir (here:
    # role first, then the playbook's own directory).
    role_dir = PluginSpecHelper.tmp_path("fileglob_relative_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    File.write(File.join(role_dir, "tasks", "01_install.yml"), "- debug: msg=hi\n")
    File.write(File.join(role_dir, "tasks", "02_remove.yml"), "- debug: msg=hi\n")
    File.write(File.join(role_dir, "tasks", "main.yml"), "- debug: msg=hi\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('ansible.builtin.fileglob', 'tasks/*.yml') | length")
      .must_equal("3")
  end

  it "still honors an explicit absolute paths: entry, unaffected by role-relative resolution" do
    role_dir = PluginSpecHelper.tmp_path("first_found_explicit_paths_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "otherdir"))
    File.write(File.join(role_dir, "otherdir", "x.yml"), "greeting: hello\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["params"] = JSON.parse(%({"files": ["x.yml"], "paths": [#{File.join(role_dir, "otherdir").to_json}]}))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('first_found', params)").must_equal(File.join(role_dir, "otherdir", "x.yml"))
  end

  it "parses an inline first_found DICT literal whose files: value is a variable holding the candidate list" do
    # Real bug found benchmarking AerisCloud.vault (round 83346): the
    # DICT form passed INLINE (not through a params variable) with a
    # task-local vars: candidate list -
    #
    #   include_vars: "{{ lookup('first_found', {'files': var_files,
    #     'paths': [ 'vars' ]}) }}"
    #   vars:
    #     var_files:
    #       - "{{ ansible_distribution }}.yml"
    #       - "{{ ansible_os_family }}.yml"
    #
    # first_found_params resolved the dict literal through the plain
    # variable-reference resolver (nil) and then the +/-operand fallback
    # (also nil, its literal branch only knows `[...]` arrays), so the
    # whole lookup collapsed to the literal text "undefined" and
    # include_vars failed "file not found: undefined" - without even
    # trying the individual candidates, where vars/Debian.yml exists
    # (Ansible: Ubuntu.yml misses, Debian.yml is found).
    role_dir = PluginSpecHelper.tmp_path("first_found_inline_dict_var_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "vars"))
    File.write(File.join(role_dir, "vars", "Debian.yml"), "greeting: hello\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["ansible_distribution"] = JSON::Any.new("Ubuntu")
    v["ansible_os_family"] = JSON::Any.new("Debian")
    v["var_files"] = JSON.parse(%(["{{ ansible_distribution }}.yml", "{{ ansible_os_family }}.yml"]))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(lookup('first_found', {'files': var_files, 'paths': [ 'vars' ]})))
      .must_equal(File.join(role_dir, "vars", "Debian.yml"))
  end

  it "parses an inline first_found DICT literal with a fully inline files: list, nested templates included" do
    role_dir = PluginSpecHelper.tmp_path("first_found_inline_dict_literal_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "vars"))
    File.write(File.join(role_dir, "vars", "Debian.yml"), "greeting: hello\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["ansible_distribution"] = JSON::Any.new("Ubuntu")
    v["ansible_os_family"] = JSON::Any.new("Debian")
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(lookup('first_found', {'files': ['{{ ansible_distribution }}.yml', 'Debian.yml'], 'paths': ['vars']})))
      .must_equal(File.join(role_dir, "vars", "Debian.yml"))
  end

  it "keeps nested candidate templates RAW inside an inline dict literal so an undefined one still fails strictly" do
    # The inline-dict parsing must not pre-render the files: entries
    # leniently (which would turn '{{ ansible_facts.os_family }}.yml'
    # into "undefined.yml" and silently lose to a later default.yml) -
    # strict per-entry rendering in evaluate_first_found must still see
    # them, same as the params-variable dict form.
    role_dir = PluginSpecHelper.tmp_path("first_found_inline_dict_strict_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "vars"))
    File.write(File.join(role_dir, "vars", "default.yml"), "greeting: hello\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    assert_raises(Krikri::UndefinedVariableError) do
      evaluator.evaluate(%(lookup('first_found', {'files': ['{{ ansible_facts.os_family }}.yml', 'default.yml'], 'paths': ['vars']})))
    end
  end

  it "evaluates a quoted string literal piped into a filter chain" do
    # `{{ 'foo' | upper }}` - a literal, not a variable, as the chain's
    # head. Previously the base-value resolution in evaluate_with_filter
    # only understood a bare variable name, `(...)`, `range(...)`, or
    # `[...]` indexing as the chain's head - a quoted literal fell to the
    # plain-lookup fallback, treating the literal text (quotes included)
    # as a variable NAME to resolve, always undefined.
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("'hello' | upper").must_equal("HELLO")
    evaluator.evaluate("'/var/log/mysql/mysql.err' | dirname").must_equal("/var/log/mysql")
  end

  it "resolves an explicit relative paths: entry against the role dir, not cwd" do
    # The actual real-world spelling that broke geerlingguy.docker/mysql/
    # postgresql: `paths: ['vars']`, an explicit but RELATIVE entry -
    # previously joined straight against the process's cwd
    # ("vars/Debian.yml"), essentially never the role's own vars/ dir a
    # ansible-playbook run resolves it against.
    role_dir = PluginSpecHelper.tmp_path("first_found_relative_paths_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "vars"))
    File.write(File.join(role_dir, "vars", "Debian.yml"), "greeting: hello\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["params"] = JSON.parse(%({"files": ["Debian.yml"], "paths": ["vars"]}))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('first_found', params)").must_equal(File.join(role_dir, "vars", "Debian.yml"))
  end

  it "supports query('first_found', ...) as a real list, not just lookup()" do
    # Real bug found benchmarking buluma.confluence (round 165):
    # `query(...)` (Ansible's lookup(..., wantlist=True) shorthand,
    # the standard idiom for `loop: "{{ query('first_found', params)
    # }}"`) was entirely unrecognized - only `lookup(` was matched,
    # so `query(...)` fell through to a plain variable-name lookup on
    # the literal call text, always "undefined".
    role_dir = PluginSpecHelper.tmp_path("query_first_found_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "vars"))
    File.write(File.join(role_dir, "vars", "Debian.yml"), "greeting: hello\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["params"] = JSON.parse(%({"files": ["Debian.yml"], "paths": ["vars"]}))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("query('first_found', params)").must_equal(%([#{File.join(role_dir, "vars", "Debian.yml").to_json}]))
  end

  it "query('first_found', ...) with no match returns an empty list, not a single undefined item" do
    # skip: true is what makes a no-match first_found tolerate the miss
    # (Ansible FAILS the task without it - see the no-match spec
    # above); without that flag this used to return the "undefined"
    # sentinel string here instead.
    v = Hash(String, JSON::Any).new
    v["params"] = JSON.parse(%({"files": ["NoSuchFile.yml"], "paths": ["/nonexistent"], "skip": true}))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("query('first_found', params)").must_equal("[]")
  end

  it "query('<unimplemented lookup type>', ...) returns an empty list, not [\"undefined\"]" do
    # Real bug found in a 150-role overnight round (manala.cron): its
    # own `loop: "{{ query('manala_cron_files_env', manala_cron_files)
    # }}"` uses a role-local CUSTOM Python lookup plugin (a real,
    # understood scope limit - krikri can't execute one). #evaluate_lookup
    # falls back to the literal string "undefined" for any lookup type
    # it doesn't implement; the generic (non-first_found) branch of
    # #evaluate_query then wrapped that AS DATA into a one-element
    # ["undefined"] array instead of treating it as "nothing resolved"
    # the way the first_found branch above already does - the loop ran
    # ONCE with a bogus string `item` instead of skipping (Ansible
    # skips: manala_cron_files is empty by default, so the role's own
    # lookup plugin - which krikri can't run - would itself return []).
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(Hash(String, JSON::Any).new)
    evaluator.evaluate("query('totally_custom_unimplemented_lookup', [])").must_equal("[]")
  end

  it "resolves a first_found paths: entry relative to the role's tasks/ dir, not just role_path itself" do
    # buluma.confluence's own idiom: `paths: ['../vars']`, meant to be
    # interpreted relative to the INCLUDING TASK FILE's own directory
    # (tasks/main.yml -> tasks/../vars == role_dir/vars) - real
    # ansible-playbook resolves it this way; this engine previously only
    # ever tried role_path itself as the base (role_dir/../vars, one
    # level too far up), never finding the real file.
    role_dir = PluginSpecHelper.tmp_path("first_found_tasks_relative_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "vars"))
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    File.write(File.join(role_dir, "vars", "Debian.yml"), "greeting: hello\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["params"] = JSON.parse(%({"files": ["Debian.yml"], "paths": ["../vars"]}))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('first_found', params)").must_equal(File.join(role_dir, "vars", "Debian.yml"))
  end

  it "evaluates lookup('env', 'VAR') for both a set and an unset environment variable" do
    # Real bug found benchmarking ansible-community.ansible-vault's own
    # `vault_version: "{{ lookup('env', 'VAULT_VERSION') | default(
    # '2.0.3', true) }}"` - lookup('env', ...) was entirely unimplemented
    # (only 'first_found' was), always "undefined" regardless of the
    # real env var.
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    ENV["CRYSTAL_ANSIBLE_SPEC_ENV_LOOKUP_TEST"] = "hello"
    evaluator.evaluate("lookup('env', 'CRYSTAL_ANSIBLE_SPEC_ENV_LOOKUP_TEST')").must_equal("hello")
    ENV.delete("CRYSTAL_ANSIBLE_SPEC_ENV_LOOKUP_TEST")

    evaluator.evaluate("lookup('env', 'CRYSTAL_ANSIBLE_SPEC_ENV_LOOKUP_TEST')").must_equal("")
  end

  it "renders a nested {{ }} span inside a lookup() string argument before using it" do
    # Ansible supports (with a deprecation warning) a lookup plugin
    # argument that is itself a quoted string CONTAINING a `{{ }}` span,
    # e.g. `lookup('file', "{{ dir }}/{{ name }}.txt")` - the inner span
    # gets rendered first, then the lookup runs against the real path.
    # Found via bodsch.tomcat's own checksum-file parsing: `lookup(
    # "file", "{{ tomcat_local_tmp_directory }}/apache-tomcat-{{
    # tomcat_version }}.tar.gz.sha512")`. Previously the literal path
    # text (quotes stripped, `{{ }}` markers untouched) was handed
    # straight to File.read, which never found the file - the lookup's
    # own "undefined" fallback then flowed into a real get_url: checksum
    # comparison ("checksum mismatch: expected undefined, got <real
    # sha512>") instead of the actual downloaded file's checksum.
    dir = File.tempname("expr_eval_lookup_spec")
    Dir.mkdir(dir)
    File.write(File.join(dir, "greeting.txt"), "hello there")

    v = Hash(String, JSON::Any).new
    v["mydir"] = JSON::Any.new(dir)
    v["myname"] = JSON::Any.new("greeting")
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate(%(lookup("file", "{{ mydir }}/{{ myname }}.txt"))).must_equal("hello there")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "evaluates lookup('vars', name) as an indirect variable lookup" do
    v = Hash(String, JSON::Any).new
    v["env_prod_port"] = JSON::Any.new(8080_i64)
    v["target_env"] = JSON::Any.new("prod")
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate(%(lookup('vars', 'env_' + target_env + '_port'))).must_equal("8080")
  end

  # Ansible's own vars lookup plugin RAISES (AnsibleUndefinedVariable,
  # "No variable named 'X' was found.") for a missing key with no
  # `default=` kwarg - it does not silently yield a placeholder. Found via
  # galaxyproject.galaxy's `set_fact: "{{ item }}": "{{ lookup('vars',
  # '__' ~ item) }}"`: krikri previously returned the literal string
  # "undefined", the set_fact "succeeded", and the play diverged 20+ tasks
  # later instead of failing right at the lookup like Ansible does.
  it "raises (does not silently return 'undefined') for lookup('vars', ...) on a missing key with no default" do
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    assert_raises_message(Krikri::UndefinedVariableError, /No variable named 'no_such_variable' was found\./) do
      evaluator.evaluate(%(lookup('vars', 'no_such_variable')))
    end
  end

  it "returns the evaluated default for lookup('vars', ...) on a missing key with an explicit default" do
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate(%(lookup('vars', 'no_such_variable', default='fallback_value'))).must_equal("fallback_value")
  end

  it "evaluates lookup('file', path) reading a controller-side file, trailing newline stripped" do
    path = PluginSpecHelper.tmp_path("lookup_file_test.txt")
    Dir.mkdir_p(File.dirname(path))
    File.write(path, "secret-content\n")

    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(lookup('file', '#{path}'))).must_equal("secret-content")
  end

  # Real bug found benchmarking ansible-lockdown.windows_11_cis (round
  # 900733): its vars/main.yml does `lookup('file', './templates/
  # banner.txt')` against a file living at the role root's templates/,
  # NOT under files/. Ansible's `file` lookup resolves terms through
  # find_file_in_search_path's two-probe search order - `<dir>/files/<term>`
  # first, then `<dir>/<term>` directly - so the caller's own subdirectory
  # components reach the role root (live-verified against real
  # ansible-playbook: the lookup succeeds; `files/` is a search HINT, not a
  # forced prefix). This engine used to unconditionally prepend files/,
  # failing with "File not found" on a path Ansible resolves.
  it "resolves a relative path with its own subdirectory component directly under the role root when no files/-prefixed match exists" do
    role_dir = PluginSpecHelper.tmp_path("lookup_relpath_role")
    Dir.mkdir_p(File.join(role_dir, "templates"))
    File.write(File.join(role_dir, "templates", "banner.txt"), "lockdown-banner\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(lookup('file', './templates/banner.txt'))).must_equal("lockdown-banner")
  end

  it "still resolves a bare filename under <role>/files/ when that is where the file is (files/ hint wins)" do
    role_dir = PluginSpecHelper.tmp_path("lookup_relpath_role")
    Dir.mkdir_p(File.join(role_dir, "files"))
    File.write(File.join(role_dir, "files", "plain.txt"), "from-files-dir\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(lookup('file', 'plain.txt'))).must_equal("from-files-dir")
  end

  # Real bug found benchmarking andrewrothstein.ssh-user-keygen (0.9.616):
  # Ansible's `file` lookup RAISES for a missing file ("Unable to
  # access the file '<path>': File not found"), failing the task's arg
  # finalization - it does NOT fall back to a placeholder the way a
  # genuinely-undefined VARIABLE reference does elsewhere in this
  # evaluator. The previous "undefined" fallback let the literal text
  # "undefined" get written straight into a real target file
  # (`~/.ssh/authorized_keys`, via `lookup('file', ssh_user_pubkey)` on
  # a host with no `~/.ssh/id_rsa.pub`) instead of failing like real
  # Ansible does.
  it "raises (does not silently return 'undefined') for lookup('file', ...) on a missing file" do
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    assert_raises_message(Exception, /lookup plugin 'file' failed.*File not found/) do
      evaluator.evaluate(%(lookup('file', '/no/such/file/at/all')))
    end
  end

  it "evaluates lookup('pipe', command) running a local shell command" do
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(lookup('pipe', 'echo hello-from-pipe'))).must_equal("hello-from-pipe")
  end

  it "renders a nested {{ }} span inside a lookup('pipe', ...) string argument (round 90013, ajeleznov.manage-known-hosts)" do
    # The role's own shape: `lookup('pipe', 'ssh-keyscan -t {{ ssh_key_type
    # }} {{ item }}{{ net_domain }}')` - ansible-core 2.19.4 renders
    # the inner spans before running the command (live-verified: the
    # lookup's failure message shows the fully-rendered command text) and
    # only WARNS about the embedded templates; this evaluator's
    # rerender_double_templated_literal handles the same rendering.
    v = Hash(String, JSON::Any).new
    v["ssh_key_type"] = JSON::Any.new("rsa")
    v["item"] = JSON::Any.new("denotsl959")
    v["net_domain"] = JSON::Any.new(".int.kn")
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(
      %(lookup('pipe', 'echo -t {{ ssh_key_type }} {{ item }}{{ net_domain }}')),
    ).must_equal("-t rsa denotsl959.int.kn")
  end

  it "raises (does not silently return 'undefined') for lookup('pipe', ...) on a non-zero exit" do
    # Ansible's pipe lookup raises on ANY non-zero exit code
    # ("The lookup plugin 'pipe' failed: lookup_plugin.pipe(<cmd>)
    # returned <rc>", live-verified against 2.19.4, stdout discarded),
    # failing the task's arg finalization. The old lenient "undefined"
    # sentinel here let ajeleznov.manage-known-hosts's failing
    # ssh-keyscan flow a literal "undefined" key into known_hosts and
    # the play run seven tasks past Ansible's hard stop.
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    assert_raises_message(Krikri::PipeLookupError, /lookup plugin 'pipe' failed: lookup_plugin\.pipe\(echo out; exit 3\) returned 3/) do
      evaluator.evaluate(%(lookup('pipe', 'echo out; exit 3')))
    end
  end

  it "returns an empty result instead of raising for lookup('pipe', ...) with errors='ignore'" do
    # Ansible's generic lookup errors='ignore' option swallows the
    # failure (live-verified against 2.19.4: `lookup('pipe', 'exit 7',
    # errors='ignore')` renders empty rather than failing).
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(lookup('pipe', 'exit 7', errors='ignore'))).must_equal("")
  end

  it "evaluates lookup('template', path) rendering a local .j2 file against expression vars" do
    path = PluginSpecHelper.tmp_path("lookup_template_test.j2")
    Dir.mkdir_p(File.dirname(path))
    File.write(path, "value is {{ my_var }}\n")

    v = Hash(String, JSON::Any).new
    v["my_var"] = JSON::Any.new("computed")
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(lookup('template', '#{path}'))).must_equal("value is computed")
  end

  it "strips a leading #jinja2: directive line from lookup('template', path)'s rendered output" do
    # Real bug found benchmarking bimdata.ferm: its own get_vars.j2
    # opens with `#jinja2: lstrip_blocks: True` (a per-template Jinja2
    # config override, metadata for the renderer - Ansible strips
    # it before rendering, same as TemplateActionPlugin already does
    # for the `template:` module). This lookup plugin never did,
    # leaking the literal "#jinja2: ..." line into the returned text -
    # fatal for the role's own `| from_json` pipeline right after this
    # lookup, which saw that line prepended to the real JSON and raised
    # "invalid JSON input".
    path = PluginSpecHelper.tmp_path("lookup_template_jinja2_directive_test.j2")
    Dir.mkdir_p(File.dirname(path))
    File.write(path, "#jinja2: lstrip_blocks: True\nvalue is {{ my_var }}\n")

    v = Hash(String, JSON::Any).new
    v["my_var"] = JSON::Any.new("computed")
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(lookup('template', '#{path}'))).must_equal("value is computed")
  end

  it "evaluates lookup('template', path, template_vars=dict(...)) merging the kwarg's dict into the rendered template's own vars" do
    # Real bug found benchmarking bimdata.ferm's own defaults/main.yml:
    # `_ferm_rules: "{{ lookup('template', 'get_vars.j2', template_vars=
    # dict(app_name='ferm', var_type='rule')) | from_json }}"` - real
    # Ansible's own template lookup plugin merges template_vars='s dict
    # into the vars available to the rendered template, on top of (never
    # replacing) the calling context's own vars. Entirely ignored
    # before - the template rendered with app_name/var_type undefined
    # regardless of what template_vars= actually passed.
    path = PluginSpecHelper.tmp_path("lookup_template_vars_kwarg_test.j2")
    Dir.mkdir_p(File.dirname(path))
    File.write(path, "{{ app_name }}-{{ my_var }}\n")

    v = Hash(String, JSON::Any).new
    v["my_var"] = JSON::Any.new("computed")
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(lookup('template', '#{path}', template_vars=dict(app_name='ferm')))).must_equal("ferm-computed")
  end

  it "evaluates lookup('password', path) generating and persisting a password across calls" do
    path = PluginSpecHelper.tmp_path("lookup_password_test.txt")
    File.delete(path) if File.exists?(path)

    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    first = evaluator.evaluate(%(lookup('password', '#{path}')))
    first.wont_be_empty
    File.exists?(path).must_equal(true)

    second = evaluator.evaluate(%(lookup('password', '#{path}')))
    second.must_equal(first)
    File.delete(path)
  end

  # `/dev/null` is Ansible's own "generate one, don't save it"
  # idiom. The generic "file exists -> read it back" branch used to win
  # (that path does exist and reads empty), so every such lookup
  # returned "" - imntreal.smallstep_ca then wrote empty password files
  # and `step ca init --password-file=<empty>` prompted interactively.
  it "evaluates lookup('password', '/dev/null') as a fresh unsaved password" do
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    first = evaluator.evaluate(%(lookup('password', '/dev/null')))
    first.wont_be_empty
    first.size.must_equal(20)

    second = evaluator.evaluate(%(lookup('password', '/dev/null')))
    second.wont_equal(first)

    evaluator.evaluate(%(lookup('password', '/dev/null length=12'))).size.must_equal(12)
    File.size("/dev/null").must_equal(0)
  end

  it "evaluates lookup('password', ...) honoring length=" do
    path = PluginSpecHelper.tmp_path("lookup_password_length_test.txt")
    File.delete(path) if File.exists?(path)

    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    result = evaluator.evaluate(%(lookup('password', '#{path} length=8')))
    result.size.must_equal(8)
    File.delete(path)
  end

  it "evaluates lookup('dict', ...) as a list of {key, value} dicts" do
    v = Hash(String, JSON::Any).new
    v["mydict"] = JSON.parse(%({"a": 1, "b": 2}))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    result = JSON.parse(evaluator.evaluate("lookup('dict', mydict)"))
    result.as_a.map { |item| {item["key"].as_s, item["value"].as_i} }.must_equal([{"a", 1}, {"b", 2}])
  end

  it "evaluates lookup('list', ...) returning every term as a list" do
    v = Hash(String, JSON::Any).new
    v["a"] = JSON::Any.new(1_i64)
    v["b"] = JSON::Any.new(2_i64)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    JSON.parse(evaluator.evaluate("lookup('list', a, b)")).as_a.map(&.as_i).must_equal([1, 2])
  end

  it "evaluates lookup('items', ...) flattening list terms one level" do
    v = Hash(String, JSON::Any).new
    v["l1"] = JSON.parse(%([1, 2]))
    v["l2"] = JSON.parse(%([3, 4]))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    JSON.parse(evaluator.evaluate("lookup('items', l1, l2)")).as_a.map(&.as_i).must_equal([1, 2, 3, 4])
  end

  it "evaluates lookup('flattened', ...) deep-flattening nested list terms" do
    v = Hash(String, JSON::Any).new
    v["l1"] = JSON.parse(%([1, [2, 3]]))
    v["l2"] = JSON.parse(%(4))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate("lookup('flattened', l1, l2)").must_equal("1,2,3,4")
    JSON.parse(evaluator.evaluate("lookup('flattened', l1, l2, wantlist=True)")).as_a.map(&.as_i).must_equal([1, 2, 3, 4])
  end

  it "evaluates lookup('together', ...) zipping lists, padding shorter ones with null" do
    v = Hash(String, JSON::Any).new
    v["l1"] = JSON.parse(%([1, 2, 3]))
    v["l2"] = JSON.parse(%(["x", "y"]))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    result = JSON.parse(evaluator.evaluate("lookup('together', l1, l2)")).as_a
    result[0].as_a.must_equal([JSON::Any.new(1_i64), JSON::Any.new("x")])
    result[2].as_a[1].raw.must_be_nil
  end

  it "evaluates lookup('nested', ...) as a Cartesian product" do
    v = Hash(String, JSON::Any).new
    v["l1"] = JSON.parse(%(["a", "b"]))
    v["l2"] = JSON.parse(%([1, 2]))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    result = JSON.parse(evaluator.evaluate("lookup('nested', l1, l2)")).as_a
    result.map { |row| row.as_a.map(&.to_s) }.must_equal([["a", "1"], ["a", "2"], ["b", "1"], ["b", "2"]])
  end

  it "supports q(...) as a full alias for query(...)" do
    # Real bug found benchmarking nephelaiio.devtools: `q(...)` is real
    # Ansible's documented short alias for `query(...)` (same lookup
    # dispatch, always the list form) - only `query(` was matched, so
    # `q('first_found', include_files, errors='ignore')` fell through to
    # a plain variable-name lookup on the literal call text, "undefined".
    role_dir = PluginSpecHelper.tmp_path("q_first_found_alias_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "vars"))
    File.write(File.join(role_dir, "vars", "Debian.yml"), "greeting: hello\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["params"] = JSON.parse(%({"files": ["Debian.yml"], "paths": ["vars"]}))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("q('first_found', params)").must_equal(%([#{File.join(role_dir, "vars", "Debian.yml").to_json}]))
    evaluator.evaluate("query('first_found', params)").must_equal(%([#{File.join(role_dir, "vars", "Debian.yml").to_json}]))
  end

  it "resolves a first_found search-list argument that is itself a variable holding a LIST" do
    # Real bug found benchmarking nephelaiio.devtools: its own idiom is
    #   include_vars: "{{ item }}"
    #   vars:
    #     include_files:
    #       - "vars/{{ ansible_distribution }}-{{ ... }}.yml"
    #       - "vars/{{ ansible_os_family }}.yml"
    #   loop: "{{ q('first_found', include_files, errors='ignore') }}"
    # Real first_found accepts, besides the {files:, paths:, skip:} DICT
    # form, a plain LIST term (flattened recursively into file candidates)
    # and a single STRING filename. This engine's evaluate_first_found
    # only handled the dict form - a list-valued variable name resolved
    # fine, then hit `params.as_h? || return "undefined"` and first_found
    # "found nothing" no matter what actually existed, so the loop was
    # empty and include_vars loaded nothing.
    role_dir = PluginSpecHelper.tmp_path("q_first_found_list_term_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "vars"))
    File.write(File.join(role_dir, "vars", "Debian.yml"), "greeting: hello\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["ansible_distribution"] = JSON::Any.new("Debian")
    v["include_files"] = JSON.parse(%(["vars/{{ ansible_distribution }}.yml", "vars/default.yml"]))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("q('first_found', include_files, errors='ignore')").must_equal(%([#{File.join(role_dir, "vars", "Debian.yml").to_json}]))
    evaluator.evaluate("query('first_found', include_files)").must_equal(%([#{File.join(role_dir, "vars", "Debian.yml").to_json}]))
    evaluator.evaluate("lookup('first_found', include_files)").must_equal(File.join(role_dir, "vars", "Debian.yml"))
  end

  it "first_found with a list term and errors='ignore' returns [] on no match instead of failing" do
    # Ansible's generic lookup `errors='ignore'` option swallows the
    # no-match failure and returns an empty result - with the list term
    # form there is no `skip:` sub-key to set, so `errors='ignore'` is
    # the ONLY way the calling role (nephelaiio.devtools again) can
    # tolerate a host where no candidate exists.
    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new("/nonexistent-role")
    v["include_files"] = JSON.parse(%(["NoSuchFile.yml"]))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("q('first_found', include_files, errors='ignore')").must_equal("[]")
    assert_raises_message(Krikri::FirstFoundLookupError, "No file was found when using first_found") do
      evaluator.evaluate("q('first_found', include_files)")
    end
  end

  it "strips trailing keyword arguments from lookup(...) positional terms" do
    # Real bug found benchmarking weakcamel.loki:
    # `lookup('nested', __loki_checksums, loki_bins, wantlist=True)` fed
    # the `wantlist=True` kwarg into the Cartesian product as a third
    # "list" term - it resolved to nothing, and any list x empty = empty,
    # collapsing the whole loop to zero iterations (Ansible iterates
    # the real product of the two lists).
    v = Hash(String, JSON::Any).new
    v["l1"] = JSON.parse(%(["a", "b"]))
    v["l2"] = JSON.parse(%([1, 2]))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    result = JSON.parse(evaluator.evaluate("lookup('nested', l1, l2, wantlist=True)")).as_a
    result.map { |row| row.as_a.map(&.to_s) }.must_equal([["a", "1"], ["a", "2"], ["b", "1"], ["b", "2"]])

    # The common no-kwarg form must behave exactly as before.
    no_kwarg = JSON.parse(evaluator.evaluate("lookup('nested', l1, l2)")).as_a
    no_kwarg.map { |row| row.as_a.map(&.to_s) }.must_equal([["a", "1"], ["a", "2"], ["b", "1"], ["b", "2"]])

    # query()/q() take the same kwarg-stripping path (via evaluate_lookup's
    # generic delegation).
    result = JSON.parse(evaluator.evaluate("q('nested', l1, l2, wantlist=True)")).as_a
    result.map { |row| row.as_a.map(&.to_s) }.must_equal([["a", "1"], ["a", "2"], ["b", "1"], ["b", "2"]])
  end

  it "evaluates lookup('lines', ...) splitting command output into a list of lines" do
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    JSON.parse(evaluator.evaluate(%(lookup('lines', 'printf "a\\nb\\nc\\n"')))).as_a.map(&.as_s).must_equal(["a", "b", "c"])
  end

  it "evaluates lookup('varnames', ...) returning matching variable NAMES, not values" do
    v = Hash(String, JSON::Any).new
    v["nginx_port"] = JSON::Any.new(80_i64)
    v["nginx_host"] = JSON::Any.new("example.com")
    v["apache_port"] = JSON::Any.new(8080_i64)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    result = JSON.parse(evaluator.evaluate(%(lookup('varnames', '^nginx_')))).as_a.map(&.as_s).sort!
    result.must_equal(["nginx_host", "nginx_port"])
  end

  it "evaluates lookup('sequence', ...) generating a numeric range" do
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    JSON.parse(evaluator.evaluate(%(lookup('sequence', 'start=1 end=3')))).as_a.map(&.as_s).must_equal(["1", "2", "3"])
  end

  it "evaluates lookup('sequence', ...) honoring the shorthand start-end form and format=" do
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    JSON.parse(evaluator.evaluate(%(lookup('sequence', '1-3 format=web%02d')))).as_a.map(&.as_s).must_equal(["web01", "web02", "web03"])
  end

  it "evaluates lookup('indexed_items', ...) as [index, item] pairs" do
    v = Hash(String, JSON::Any).new
    v["l"] = JSON.parse(%(["a", "b"]))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    result = JSON.parse(evaluator.evaluate("lookup('indexed_items', l)")).as_a
    result.map { |pair| {pair[0].as_i, pair[1].as_s} }.must_equal([{0, "a"}, {1, "b"}])
  end

  it "evaluates lookup('random_choice', ...) returning one element from the combined lists" do
    v = Hash(String, JSON::Any).new
    v["l"] = JSON.parse(%(["only"]))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate("lookup('random_choice', l)").must_equal("only")
  end

  it "evaluates lookup('community.general.random_string', ...) generating a base64 secret" do
    # juju4.pocketid's own idiom: length=secretlength, base64=secretbase64,
    # both variables - the FQ collection name must reach the bare-name
    # dispatch, and the kwargs' VALUES may be variable references.
    v = Hash(String, JSON::Any).new
    v["secretlength"] = JSON::Any.new(64_i64)
    v["secretbase64"] = JSON.parse("true")
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    result = evaluator.evaluate("lookup('community.general.random_string', length=secretlength, base64=secretbase64)")
    decoded = Base64.decode_string(result)
    decoded.size.must_equal(64)
    decoded.each_char.all? { |chr| chr.ascii_alphanumeric? || ('!'..'~').covers?(chr) }.must_equal(true)
  end

  it "evaluates lookup('random_string', ...) with default length 8" do
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('random_string')").size.must_equal(8)
  end

  it "evaluates lookup('random_string', seed=...) reproducibly" do
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    first = evaluator.evaluate(%(lookup('random_string', length=16, seed='abc')))
    second = evaluator.evaluate(%(lookup('random_string', length=16, seed='abc')))
    first.size.must_equal(16)
    first.must_equal(second)
  end

  it "evaluates lookup('random_string', ...) honoring min_* guarantees against a restricted pool" do
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    result = evaluator.evaluate(%(lookup('random_string', length=5, min_upper=2, min_numeric=1, lower=false, numbers=false, special=false)))
    result.size.must_equal(5)
    result.count(&.ascii_uppercase?).must_equal(4)
    result.count(&.ascii_number?).must_equal(1)
  end

  it "raises lookup('random_string', ...) on an empty character pool like Ansible" do
    # The real plugin's get_random() is called unconditionally with the
    # built pool and raises even when the remaining count is zero, so
    # disabling every class flag fails the task there too - this mirrors
    # that rather than papering over it.
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    assert_raises_message(Exception, "Available characters cannot be None, please change constraints") do
      evaluator.evaluate(%(lookup('random_string', length=3, upper=false, lower=false, numbers=false, special=false)))
    end
  end

  it "evaluates lookup('merge_variables', ...) returning initial_value when no variable matches" do
    # thulium_drake.sshd (round 813042): the role defines
    # sshd_configs: "{{ lookup('community.general.merge_variables',
    # '_sshd_configs__to_merge', pattern_type='suffix',
    # initial_value=[]) }}" with NO variable ending in the suffix -
    # Ansible returns the initial_value untouched (so
    # `when: sshd_configs | length > 0` skips cleanly), while the
    # missing lookup used to fall through to the "undefined" fallback
    # and hard-fail the loop as an UndefinedVariableError.
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate("lookup('merge_variables', 'somesuffix', pattern_type='suffix', initial_value=[])").must_equal("[]")
    evaluator.evaluate("lookup('merge_variables', 'somesuffix', pattern_type='suffix', initial_value=[]) | length").must_equal("0")
  end

  it "evaluates lookup('merge_variables', ...) concatenating matching list-valued variables in name order" do
    v = Hash(String, JSON::Any).new
    v["role_b__configs"] = JSON.parse(%(["b"]))
    v["role_a__configs"] = JSON.parse(%(["a"]))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    result = JSON.parse(evaluator.evaluate("lookup('merge_variables', '__configs', pattern_type='suffix')")).as_a
    result.map(&.as_s).must_equal(["a", "b"])
  end

  it "evaluates lookup('merge_variables', ...) deep-merging matching dicts with pattern_type='prefix'" do
    v = Hash(String, JSON::Any).new
    v["sshd__config_a"] = JSON.parse(%({"Port": 22, "PermitRootLogin": "yes"}))
    v["sshd__config_b"] = JSON.parse(%({"PermitRootLogin": "no"}))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    result = JSON.parse(evaluator.evaluate("lookup('merge_variables', 'sshd__config', pattern_type='prefix')")).as_h
    result["Port"].as_i.must_equal(22)
    result["PermitRootLogin"].as_s.must_equal("no")
  end

  it "evaluates lookup('subelements', ...) yielding [parent, child] pairs" do
    v = Hash(String, JSON::Any).new
    v["users"] = JSON.parse(%([{"name": "alice", "groups": ["a", "b"]}, {"name": "bob", "groups": ["c"]}]))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    result = JSON.parse(evaluator.evaluate("lookup('subelements', users, 'groups')")).as_a
    result.size.must_equal(3)
    result[0].as_a[0].as_h["name"].as_s.must_equal("alice")
    result[0].as_a[1].as_s.must_equal("a")
  end

  it "evaluates lookup('csvfile', ...) finding a row by key and returning a column" do
    path = PluginSpecHelper.tmp_path("lookup_csvfile_test.csv")
    File.write(path, "alice,30,engineer\nbob,25,designer\n")

    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(lookup('csvfile', 'bob file=#{path} delimiter=, col=2'))).must_equal("designer")
    File.delete(path)
  end

  it "evaluates lookup('ini', ...) reading a value from a section" do
    path = PluginSpecHelper.tmp_path("lookup_ini_test.ini")
    File.write(path, "[web]\nport = 8080\n\n[db]\nport = 5432\n")

    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(lookup('ini', 'port section=db file=#{path}'))).must_equal("5432")
    File.delete(path)
  end

  it "evaluates lookup('unvault', ...) decrypting a file with the session's vault password" do
    with_vault do
      path = PluginSpecHelper.tmp_path("lookup_unvault_test.txt")
      File.write(path, Krikri::Vault.encrypt("top secret", "runpassword"))
      Krikri::Vault.password = "runpassword"

      v = Hash(String, JSON::Any).new
      evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
      evaluator.evaluate(%(lookup('unvault', '#{path}'))).must_equal("top secret")

      File.delete(path)
    end
  end

  it "resolves lookup(...) followed by a filter chain, not swallowing the whole thing as one bare call" do
    # Real bug found alongside the env lookup above: `lookup('env',
    # 'VAULT_VERSION') | default('2.0.3', true)` - the naive `starts_with
    # ("lookup(") && ends_with(')')` check in evaluate_expr matched the
    # *whole* string (default(...)'s own closing paren satisfies
    # ends_with(')') too, not just lookup(...)'s), swallowing the entire
    # filter chain into evaluate_lookup as one garbled, unbalanced
    # argument before top_level_pipe?/evaluate_with_filter ever got a
    # chance to split it properly. An unset env var with no matching
    # default(..., true) call previously stayed the literal string
    # "undefined" (non-empty, so default()'s own falsy check never fired
    # even once reached) instead of "" (Ansible's own lookup('env',
    # ...) return for an unset var).
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate(%(lookup('env', 'CRYSTAL_ANSIBLE_SPEC_ENV_LOOKUP_TEST_2') | default('2.0.3', true))).must_equal("2.0.3")
  end

  it "applies a .method() chained directly onto lookup(...) with no | filter in between (round 199, bodsch.tomcat)" do
    # filter_chain_special_head's own `lookup(` branch assumed the call's
    # matching close paren was var_expr's LAST character - true when a
    # `|` filter follows (split_chain isolates the call before this
    # runs), false for a bare trailing method call with no `|` at all:
    # `lookup(...).splitlines()`'s own closing paren is what
    # ends_with?(')') actually matched, so the old slice produced a
    # garbled, unbalanced lookup() argument string.
    path = PluginSpecHelper.tmp_path("lookup_splitlines_test.txt")
    File.write(path, "line one\nline two\n")

    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(lookup('file', '#{path}').splitlines() | length)).must_equal("2")
    File.delete(path)
  end

  it "applies a .method() chained directly onto lookup(...) with no filter chain at all (a bare mustache)" do
    # Sibling bug to the one above, in evaluate_expr_bare_call's own
    # separate `lookup(` dispatch (reached when there's no `|` anywhere
    # in the expression) - bare_call? requires the lookup call's own
    # matching close paren to be the WHOLE expression's last character,
    # which a trailing `.splitlines()` breaks, so this fell through to a
    # plain variable-name lookup on the literal text and always resolved
    # "undefined".
    path = PluginSpecHelper.tmp_path("lookup_splitlines_bare_test.txt")
    File.write(path, "line one\nline two\n")

    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    result = evaluator.evaluate(%(lookup('file', '#{path}').splitlines()))
    (JSON.parse(result) rescue JSON::Any.new(result)).as_a.map(&.as_s).must_equal(["line one", "line two"])
    File.delete(path)
  end

  it "still routes lookup(...) | default(...) through the filter-chain dispatch, not the method-suffix one" do
    # Regression guard for the fix above: a bare mustache lookup(...)
    # whose "suffix" is actually a ` | filter` pipe, not a `.method()`
    # continuation, must still reach top_level_pipe?/split_chain
    # unchanged - the new lookup(...).method() dispatch only fires when
    # the text right after lookup(...)'s own closing paren is a literal
    # "." continuation.
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(lookup('env', 'CRYSTAL_ANSIBLE_SPEC_ENV_LOOKUP_TEST_3') | default('2.0.3', true))).must_equal("2.0.3")
  end

  it "evaluates an else-less inline if as empty string when the condition is false" do
    # Real bug found benchmarking ansible-community.ansible-vault's own
    # `vault_version_release_site_suffix: "{{ '+ent' if vault_enterprise
    # }}{{ '.hsm' if vault_enterprise_hsm }}"` - Jinja2 renders the
    # missing else branch as "" (Undefined's default __str__), but this
    # fell through to plain variable lookup on the literal text `'+ent' if
    # vault_enterprise`, always resolving to "undefined".
    v = Hash(String, JSON::Any).new
    v["vault_enterprise"] = JSON::Any.new(false)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%('+ent' if vault_enterprise)).must_equal("")

    v["vault_enterprise"] = JSON::Any.new(true)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%('+ent' if vault_enterprise)).must_equal("+ent")
  end

  it "renders a ternary whose CHOSEN branch is undefined as the undefined sentinel, not the empty string" do
    # Differential-fuzz fix: `{{ missing_var if bool_true else 'x' }}`
    # rendered "" through the krikri-jinja render finalization (the
    # Crinja-first path's render! of a top-level Undefined) but the
    # "undefined" sentinel through JinjaRenderer#evaluate_value! (the
    # delegation path) - two wrong answers disagreeing with each other
    # (Ansible's StrictUndefined fails the task in either shape).
    # A bare undefined reference already gives "undefined" on both sides,
    # so the sentinel is the codebase's established convention. The
    # else-less ternary keeps its "" render (the next spec): there the
    # empty string is load-bearing for real roles.
    v = Hash(String, JSON::Any).new
    v["bool_true"] = JSON::Any.new(true)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("missing_var if bool_true else 'x'").must_equal("undefined")
    evaluator.evaluate("'a' if bool_true else missing_var").must_equal("a")
    evaluator.evaluate("missing_a if bool_false else missing_b").must_equal("undefined")
  end

  it "resolves a ternary whose chosen branch is a filter chain producing an Array, as JSON not Python-repr" do
    # Real bug found via RedHatOfficial.rhel8_pci_dss's own "Set
    # gpgcheck=1 for each yum repo" loop source: `loop: "{{
    # repo_grep_results.stdout | regex_findall('(.+\.repo):\[(.+)\]\n?')
    # if repo_grep_results is not skipped else [] }}"`. The chosen
    # branch is a filter chain, not a scalar literal - #evaluate used
    # to stringify it through Crinja's own Python-repr Finalizer
    # (single-quoted, e.g. "[['a.repo', 'sec1']]") instead of this
    # codebase's JSON-compact round-trip format, so
    # resolve_loop_template's own JSON.parse of the result failed and
    # the whole unparsed repr string became ONE loop item instead of
    # the real list - `item[0]` then indexed into a String, "'item[0]'
    # is undefined".
    v = Hash(String, JSON::Any).new
    v["haystack"] = JSON::Any.new("a.repo:[sec1]\nb.repo:[sec2]\n")
    v["cond"] = JSON::Any.new(true)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    result = evaluator.evaluate(%(haystack | regex_findall('(.+\\.repo):\\[(.+)\\]\\n?') if cond else []))
    JSON.parse(result).must_equal(JSON.parse(%([["a.repo","sec1"],["b.repo","sec2"]])))
  end

  it "resolves a ternary whose branches are bare boolean literals, not quoted strings" do
    # Real bug found benchmarking ansible-community.ansible-vault's own
    # `vault_tls_copy_keys: "{{ false if (vault_install_hashi_repo) else
    # true }}"` - the chosen branch's bare `true`/`false` text (as
    # opposed to a quoted string literal like '+ent') fell through to a
    # plain variable lookup on that literal identifier, always
    # "undefined" - which `| bool` downstream then treated as truthy
    # regardless of the actual condition.
    # Real Python/Jinja2 stringifies a bare boolean as "True"/"False"
    # (capitalized), not Crystal's lowercase "true"/"false" - verified
    # directly against real Python's own jinja2.Environment.
    v = Hash(String, JSON::Any).new
    v["vault_install_hashi_repo"] = JSON::Any.new(false)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("false if vault_install_hashi_repo else true").must_equal("True")

    v["vault_install_hashi_repo"] = JSON::Any.new(true)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("false if vault_install_hashi_repo else true").must_equal("False")
  end

  it "re-templates a filter chain's own head variable when its raw value is still unrendered Jinja" do
    # Real bug found benchmarking ansible-community.ansible-vault's own
    # `vault_tls_gossip: "{{ lookup('env', 'VAULT_TLS_GOSSIP') | default(
    # false, true) }}"` used later as `vault_tls_gossip | bool` - the
    # filter chain's own head-variable resolution (the plain-lookup
    # fallback in evaluate_with_filter) returned the raw, unrendered
    # template text unchanged, which is a non-empty string - so `| bool`
    # saw it as truthy regardless of what it actually rendered to.
    v = Hash(String, JSON::Any).new
    v["vault_tls_gossip"] = JSON::Any.new(%({{ lookup('env', 'CRYSTAL_ANSIBLE_SPEC_FILTER_ENV_TEST') | default(false, true) }}))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("vault_tls_gossip | bool").must_equal("False")

    ENV["CRYSTAL_ANSIBLE_SPEC_FILTER_ENV_TEST"] = "true"
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("vault_tls_gossip | bool").must_equal("True")
    ENV.delete("CRYSTAL_ANSIBLE_SPEC_FILTER_ENV_TEST")
  end

  it "concatenates operands with Jinja2's `~` string-concat operator" do
    # Real bug found benchmarking ansible-community.ansible-vault's own
    # `vault_version~('+ent' if vault_enterprise)` (a bare-`~`
    # concatenation whose right operand is itself a parenthesized,
    # else-less ternary) - `~` was entirely unimplemented anywhere in the
    # engine, so the whole expression fell through to a plain (always-
    # undefined) variable lookup on the literal text.
    v = Hash(String, JSON::Any).new
    v["vault_version"] = JSON::Any.new("2.0.3")
    v["vault_enterprise"] = JSON::Any.new(false)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("vault_version~('+ent' if vault_enterprise)").must_equal("2.0.3")

    v["vault_enterprise"] = JSON::Any.new(true)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("vault_version~('+ent' if vault_enterprise)").must_equal("2.0.3+ent")
  end

  it "renders a bare numeric literal, alone or as a filter chain's own head" do
    # Real bug found in the same investigation as the */÷ arithmetic fix
    # below: a bare numeric literal was never checked anywhere in this
    # dispatch chain on its own (only ever as an *operand* inside a
    # `+`/`-`/`*`/`/` expression) - `{{ 5 }}` alone, or `{{ 5.7 | int
    # }}` (a literal float piped straight into a filter, no variable or
    # arithmetic involved), both fell through to a plain variable-name
    # lookup on the literal digit text itself, always "undefined".
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate("5").must_equal("5")
    evaluator.evaluate("5.7").must_equal("5.7")
    evaluator.evaluate("5.7 | int").must_equal("5")
    evaluator.evaluate("(5.7) | int").must_equal("5")
  end

  it "evaluates *, /, and // arithmetic, matching Jinja2/Python semantics exactly" do
    # Real bug found benchmarking geerlingguy.swap's own check-size.yml:
    # `(swap_file_check.stat.size / 1024 / 1024) | int` (converting a
    # stat'd byte count to MB) - `*`/`/`/`//` were entirely unimplemented
    # anywhere in the engine (only `+`/`-`/`~` had top-level operator
    # support), so even a bare `{{ 10 / 2 }}` rendered the literal
    # string "undefined". The whole file-size comparison this feeds
    # always differed, deleting and recreating the swap file on every
    # single run instead of converging. Values verified directly against
    # real Python's own jinja2.Environment: `/` always produces a float
    # (true division, even when evenly divisible), `*` preserves int
    # when both operands are int, `//` floors to int, and `*`/`/` bind
    # tighter than `+`/`-` (`2 + 3 * 4` == 14, not 20).
    v = Hash(String, JSON::Any).new
    v["n"] = JSON::Any.new(268435456_i64)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate("10 / 2").must_equal("5.0")
    evaluator.evaluate("10 / 3").must_equal("3.3333333333333335")
    evaluator.evaluate("10 // 3").must_equal("3")
    evaluator.evaluate("10 * 2").must_equal("20")
    evaluator.evaluate("2.5 * 2").must_equal("5.0")
    evaluator.evaluate("2 + 3 * 4").must_equal("14")
    evaluator.evaluate("n / 1024 / 1024").must_equal("256.0")
  end

  it "repeats strings/lists for Python-valid `*` pairs and raises on invalid ones" do
    # Differential-fuzz fix: combine_mult_div used to collapse every
    # non-numeric operand pair to JSON null (rendered as ""), so even the
    # VALID Python repeat shapes (`'-' * 40`, a Ansible idiom)
    # rendered empty while Ansible repeats them, and the invalid
    # ones (`str * list`, `str / float`) were silently answered where
    # Jinja2 raises TypeError and ansible-playbook fails the
    # task. Also fixed en route: split_top_level_mult_div discarded the
    # `//` operator step's own skip-ahead return value, splitting `//`
    # twice (parts ["10", "", "0"], ops ["//", "/"]) - the phantom empty
    # operand combined to null, silently papering over every `//` the
    # Crinja-first attempt didn't handle.
    v = Hash(String, JSON::Any).new
    v["str_plain"] = JSON::Any.new("ab")
    v["list_ints"] = JSON.parse(%([3, 1]))
    v["str_num"] = JSON::Any.new("17")
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate("'ab' * 3").must_equal("ababab")
    evaluator.evaluate("3 * 'ab'").must_equal("ababab")
    evaluator.evaluate("'ab' * -1").must_equal("")
    evaluator.evaluate("list_ints * 2").must_equal("[3, 1, 3, 1]")
    evaluator.evaluate("2 * list_ints").must_equal("[3, 1, 3, 1]")

    assert_raises_message(Krikri::PlusMinusOperandError, /unsupported operand type\(s\) for \*/) do
      evaluator.evaluate("str_plain * list_ints")
    end
    assert_raises_message(Krikri::PlusMinusOperandError, /unsupported operand type\(s\) for \*\: 'str' and 'float'/) do
      evaluator.evaluate("'ab' * 2.0")
    end
    assert_raises_message(Krikri::PlusMinusOperandError, /unsupported operand type\(s\) for \//) do
      evaluator.evaluate("str_num / 17.3")
    end
    assert_raises_message(Krikri::PlusMinusOperandError, /unsupported operand type\(s\) for \//) do
      evaluator.evaluate("missing_var / 2")
    end
  end

  it "raises on a unary minus over a missing or non-numeric operand" do
    # Differential-fuzz fix: `- missing_var` / `- 'abc'` / `- dict_var`
    # fell through to a plain variable lookup and silently rendered the
    # "undefined" sentinel where Jinja2/Ansible fails the task
    # (cannot negate / bad operand type for unary -). Numeric operands
    # keep negating; an operand shape the evaluator can't resolve
    # conservatively still falls back leniently instead of becoming a
    # spurious task failure.
    v = Hash(String, JSON::Any).new
    v["int_neg"] = JSON::Any.new(-7_i64)
    v["str_plain"] = JSON::Any.new("ab")
    v["dict_simple"] = JSON.parse(%({"a": 1}))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate("- int_neg").must_equal("7")
    evaluator.evaluate("- (5)").must_equal("-5")

    assert_raises_message(Krikri::PlusMinusOperandError, /'missing_var' is undefined/) do
      evaluator.evaluate("- missing_var")
    end
    assert_raises_message(Krikri::PlusMinusOperandError, /bad operand type for unary -/) do
      evaluator.evaluate("- 'abc'")
    end
    assert_raises_message(Krikri::PlusMinusOperandError, /bad operand type for unary -/) do
      evaluator.evaluate("- dict_simple")
    end
  end

  it "raises on an out-of-range index in every operand position, not just a bare bracket" do
    # Differential-fuzz fix (krikri-jinja v0.4.22): the engine now raises
    # Jinja2's "list object has no element N" for an out-of-range
    # subscript, and every hand-rolled path that delegates to it must
    # propagate that instead of degrading to the lenient "undefined"
    # sentinel - a `~` operand, a filter-chain result's index, a lazy
    # generator's index, and a literal-array index all used to answer
    # leniently where Ansible fails the task.
    v = Hash(String, JSON::Any).new
    v["list_nested"] = JSON.parse(%([[1, 2], [3, 4]]))
    v["list_empty"] = JSON.parse(%([]))
    v["str_plain"] = JSON::Any.new("ab")
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    assert_raises_message(Krikri::UndefinedVariableError, /has no (element|attribute) 9/) do
      evaluator.evaluate("(14 ~ list_nested[9]) | list")
    end
    assert_raises_message(Krikri::UndefinedVariableError, /has no (element|attribute) 0/) do
      evaluator.evaluate("(list_empty | unique)[0]")
    end
    assert_raises_message(Krikri::UndefinedVariableError, /has no (element|attribute) 1/) do
      evaluator.evaluate("[18.0][1]")
    end
    assert_raises_message(Krikri::UndefinedVariableError, /has no (element|attribute) 2/) do
      evaluator.evaluate("(list_empty | sort)[2]")
    end
  end

  it "coerces Bool operands to their Python int values in + arithmetic" do
    # Real bug found benchmarking galaxyproject.galaxy: its very first
    # task is `assert: that: "(galaxy_manage_clone + galaxy_manage_
    # download + galaxy_manage_existing) <= 1"` with three boolean role
    # defaults (yes/no/no). Real Python's bool is an int subclass, so
    # `True + False + False` is 1 and the assert passes; krikri's `+`
    # fell through to the string-concat fallback ("TrueFalseFalse") and
    # the assert failed before any real work ran. Fixed in BOTH
    # evaluators: the hand-rolled +/- combines (this file) and the
    # vendored Crinja fork's Value#number?/as_number
    # (crinja_bool_arithmetic.cr - the parenthesized shape routes
    # through ExpressionEvaluator's Crinja-first leading-paren path).
    v = Hash(String, JSON::Any).new
    v["galaxy_manage_clone"] = JSON::Any.new(true)
    v["galaxy_manage_download"] = JSON::Any.new(false)
    v["galaxy_manage_existing"] = JSON::Any.new(false)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate("galaxy_manage_clone + galaxy_manage_download + galaxy_manage_existing").must_equal("1")
    evaluator.evaluate("true + true").must_equal("2")
    evaluator.evaluate("true - false").must_equal("1")
    evaluator.evaluate("false + false").must_equal("0")
    evaluator.evaluate("true * 2").must_equal("2")
    evaluator.evaluate("true * 2.5").must_equal("2.5")
    evaluator.evaluate("true + 1").must_equal("2")
  end

  it "passes the exact galaxyproject.galaxy mutual-exclusion assert shape" do
    # The role's own defaults/vars shape, evaluated both the way the
    # role writes it (parenthesized, via the Crinja-first leading-paren
    # path) and as a bare when:/assert: condition (ConditionalEvaluator).
    v = Hash(String, JSON::Any).new
    v["galaxy_manage_clone"] = JSON::Any.new(true)
    v["galaxy_manage_download"] = JSON::Any.new(false)
    v["galaxy_manage_existing"] = JSON::Any.new(false)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate("(galaxy_manage_clone + galaxy_manage_download + galaxy_manage_existing) <= 1").must_equal("True")
    evaluator.evaluate("(true + false + false) <= 1").must_equal("True")
    Krikri::ConditionalEvaluator.evaluate("(galaxy_manage_clone + galaxy_manage_download + galaxy_manage_existing) <= 1", v).must_equal(true)
    Krikri::ConditionalEvaluator.evaluate("galaxy_manage_clone - galaxy_manage_download == 1", v).must_equal(true)
  end

  it "leaves non-arithmetic Bool handling (and/or/not, truthiness, equality) unchanged" do
    # The bool-is-int fix is scoped to arithmetic operators - truthiness,
    # boolean logic and Bool-vs-Bool equality keep their existing
    # (already-correct) behavior.
    v = Hash(String, JSON::Any).new
    v["a"] = JSON::Any.new(true)
    v["b"] = JSON::Any.new(false)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate("a").must_equal("True")
    evaluator.evaluate("b").must_equal("False")
    evaluator.evaluate("a and b").must_equal("False")
    evaluator.evaluate("a or b").must_equal("True")
    evaluator.evaluate("not b").must_equal("True")
    evaluator.evaluate("a and not b").must_equal("True")
    evaluator.evaluate("a == true").must_equal("True")
    evaluator.evaluate("b == false").must_equal("True")
  end

  it "doesn't crash on integer floor division by zero" do
    # `10 // 0` previously raised an uncaught OverflowError (`(10.0 /
    # 0.0).floor` is Float64::INFINITY, and `Infinity.to_i64` overflows
    # Int64) - found probing whether */,/// were safe to converge to
    # Crinja-first as part of the dual-evaluator convergence. `/`'s own by-zero case already
    # degrades leniently to "Infinity" rather than raising; `//` now
    # matches that convention (nil/"undefined") instead of crashing.
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("10 // 0").must_equal("")
  end

  it "evaluates a full boolean expression (is test, or, comparison) inside a plain {{ }} span" do
    # Real bug found benchmarking ansible-community.ansible-vault's own
    # `installation_required: "{{ vault_installation is failed or
    # installed_vault_version.stdout != vault_version~(...) }}"` -
    # ConditionalEvaluator (used for bare when:/failed_when:/assert
    # conditions) already understood `is failed`/`or`/comparisons, but
    # this evaluator (used for {{ }} spans, e.g. set_fact: values) had no
    # concept of any of the three - `is failed` alone rendered
    # "undefined", and the whole `or` expression fell through to a plain
    # (always-undefined) variable lookup on the literal text, which
    # formatted as truthy "True" regardless of the real values.
    v = Hash(String, JSON::Any).new
    v["result"] = JSON.parse(%({"failed": false}))
    v["a"] = JSON::Any.new("x")
    v["b"] = JSON::Any.new("x")
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("result is failed or a != b").must_equal("False")

    v["b"] = JSON::Any.new("y")
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("result is failed or a != b").must_equal("True")
  end

  it "treats a plain-value `or`/`and` as a value-selector, not a boolean coercion" do
    # Real bug found benchmarking robertdebock.users: `groups: "{{
    # user.groups | default([]) | join(',') or omit }}"` - since neither
    # operand is a boolean condition (no comparison/is-test), real
    # Jinja2's `or` must return the joined string itself when truthy,
    # not the literal text "True". The fix above only added boolean
    # coercion for genuine conditions; a plain "X or Y" previously still
    # rendered "True"/"False" regardless of X/Y's actual values -
    # `useradd: group 'True' does not exist` was the resulting failure.
    v = Hash(String, JSON::Any).new
    v["groups"] = JSON.parse(%(["ops", "sudo"]))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("groups | join(',') or omit").must_equal("ops,sudo")

    v["groups"] = JSON.parse(%([]))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("groups | join(',') or omit").must_equal(Krikri::OMIT_SENTINEL)

    v2 = Hash(String, JSON::Any).new
    evaluator2 = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v2)
    evaluator2.evaluate("'ops,sudo' or 'fallback'").must_equal("ops,sudo")
    evaluator2.evaluate("'' or 'fallback'").must_equal("fallback")
    evaluator2.evaluate("5 or 'fallback'").must_equal("5")
  end

  it "treats a plain-value `and` as a value-selector too" do
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("'first' and 'second'").must_equal("second")
    evaluator.evaluate("'' and 'second'").must_equal("")
  end

  it "resolves a dict.get() call whose key argument itself contains indexing" do
    # Real bug found benchmarking prometheus.prometheus.node_exporter's
    # own `_node_exporter_go_ansible_arch` default: `{'x86_64': 'amd64',
    # ...}.get(ansible_facts['architecture'], ansible_facts
    # ['architecture'])`. evaluate_bracket_or_dict_expr's own
    # `expr.includes?("[")` was a blunt any-position check - the `[`
    # nested inside .get()'s own argument wrongly routed the WHOLE
    # expression to indexed-access handling instead of the dotted
    # method-call dispatch its own top-level structure actually needs.
    v = Hash(String, JSON::Any).new
    v["ansible_facts"] = JSON.parse(%({"architecture": "x86_64"}))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate(%({'x86_64': 'amd64'}.get(ansible_facts['architecture'], ansible_facts['architecture']))).must_equal("amd64")
  end

  it "converges dict(iterable) positional form (0.9.340)" do
    # prometheus.prometheus.node_exporter's `dict(raw.splitlines() |
    # map(...) | map('flatten') | map('reverse'))` builds a checksum
    # lookup from a positional iterable of [key,value] pairs. Previously
    # this routed through hand-rolled evaluate_dict_call. Now try-Crinja
    # first (fork crystal-play-0.9.4 fixed dict()'s kernel-args-only
    # empty-dict bug); the fallback is identical if anything raises.
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(dict([['a', 1], ['b', 2]]))).must_equal(%({"a":1,"b":2}))
    evaluator.evaluate(%(dict({'x': 'y'}))).must_equal(%({"x":"y"}))
  end

  it "renders to_datetime(...) - to_datetime(...) .days through Crinja (0.9.341)" do
    # dev-sec os_hardening's password-ageing assert: `( a | to_datetime -
    # b | to_datetime ).days`. The leading-paren construct routes the WHOLE
    # expression to Crinja first; fork Time arithmetic (crystal-play-0.9.5)
    # + jinja_filters.cr's to_datetime (Ansible-specific) make it succeed
    # in one pass instead of falling back to the hand-rolled tagged-JSON
    # path. Either way the answer is the same - this pins it.
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(
      %(( 'Jan 02, 2024' | to_datetime('%b %d, %Y') - 'Jan 01, 2024' | to_datetime('%b %d, %Y') ).days)
    ).must_equal("1")
  end

  it "walks a chained numeric dot-index (.0.0) into a parenthesized filter result" do
    # Real bug found benchmarking xolyu.mariadb (round 813338): its own
    # tasks/main.yml computes `mariadb_version.major`/`.minor`/`.build`
    # via `( item | regex_findall(_regex_ver_components) ).0.0` (and
    # `.0.1`/`.0.2`) - Ansible resolves "10"/"6"/"12" from a
    # version string like "10.6.12-MariaDB". Crinja handles a SINGLE
    # dotted level on a paren-wrapped result natively, but raises on
    # `regex_findall` (a filter it doesn't implement), forcing the
    # whole leading-paren expression into ExpressionEvaluator's own
    # `walk` fallback - whose `'.'` case only understood Hash key
    # lookup, with no Array branch at all (unlike the already-correct
    # `apply_dotted_parts` used elsewhere). A SECOND chained dotted
    # level landing there silently returned "undefined" instead of
    # indexing into the nested list `regex_findall` returns.
    v = Hash(String, JSON::Any).new
    v["item"] = JSON::Any.new("10.6.12-MariaDB")
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate(
      %(( item | regex_findall('(\\d+)\\.(\\d+)\\.(\\d+)-MariaDB') ).0.0)
    ).must_equal("10")
    evaluator.evaluate(
      %(( item | regex_findall('(\\d+)\\.(\\d+)\\.(\\d+)-MariaDB') ).0.1)
    ).must_equal("6")
    evaluator.evaluate(
      %(( item | regex_findall('(\\d+)\\.(\\d+)\\.(\\d+)-MariaDB') ).0.2)
    ).must_equal("12")
  end

  it "compares a dotted operand against a `~`-concatenated one, full ansible-vault expression" do
    # End-to-end regression for the exact expression benchmarked from
    # ansible-community.ansible-vault's own "Compute if installation is
    # required" task: `installed_vault_version.stdout != vault_version~
    # ('+ent' if vault_enterprise)`. Comparison operators must be
    # detected (has_comparison?) before the `~` split ever runs, or the
    # whole thing gets sliced on `~` first instead of `!=` - covering the
    # dispatch-order interaction directly, on top of the narrower
    # ComparisonEvaluator-only and ExpressionEvaluator-only specs above.
    v = Hash(String, JSON::Any).new
    v["installed_vault_version"] = JSON.parse(%({"stdout": "2.0.3"}))
    v["vault_version"] = JSON::Any.new("2.0.3")
    v["vault_enterprise"] = JSON::Any.new(false)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("installed_vault_version.stdout != vault_version~('+ent' if vault_enterprise)").must_equal("False")
  end

  it "evaluates a bare quoted string literal with no filter/operator at all" do
    # Real bug found benchmarking cloudalchemy.prometheus: a bare
    # literal containing a `.` (routine for a URL or IP address -
    # `lookup('url', '...' + version + '...')`'s own URL argument, once
    # split out and re-evaluated as its own operand) fell through to
    # the `expr.includes?(".")` dotted-lookup branch, which treated the
    # literal text - quotes included - as a dotted variable PATH rather
    # than a plain string value, always undefined. No prior spec covered
    # a bare `{{ '...' }}` span with no `|`/ternary/operator at all.
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%('http://127.0.0.1:8080/some.file.txt')).must_equal("http://127.0.0.1:8080/some.file.txt")
  end

  it "does not mistake a `+` chain starting and ending in quotes for one bare literal" do
    # Real regression introduced fixing the bug above: the bare-literal
    # check used #quoted_string_literal (first/last char only), which
    # also matches `'a' + var + 'b'` - both ends are quotes too, just not
    # the SAME literal. Caught immediately via cloudalchemy.prometheus's
    # own `lookup('url', 'https://...v' + prometheus_version + '/...',
    # wantlist=True)` - the URL argument gets re-evaluated as its own
    # bare operand, and the naive check stripped only the outer quotes,
    # leaving " + prometheus_version + " as literal garbage text in the
    # middle of the "URL".
    v = Hash(String, JSON::Any).new
    v["prometheus_version"] = JSON::Any.new("2.27.0")
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%('https://example.com/v' + prometheus_version + '/sums.txt')).must_equal("https://example.com/v2.27.0/sums.txt")
  end

  it "routes a slice with both bounds present to ArraySlicer, not just an empty-bound slice" do
    # Real bug found probing whether the `[`-dispatch branch was safe to
    # converge to Crinja-first as part of the dual-evaluator convergence: the slice-detection
    # check was `expr.includes?("[:") || expr.includes?(":]")`, which
    # only matches an EMPTY start or end (`items[:3]`, `items[2:]`) -
    # `items[1:3]` (both bounds present) has neither literal substring
    # (a digit sits between `[`/`:` and between `:`/`]`), so it fell
    # through to `@lookup.indexed`, which has no slice handling at all,
    # always resolving to "undefined" even though `ArraySlicer#slice`
    # itself handles this exact input correctly when called directly.
    v = Hash(String, JSON::Any).new
    v["items"] = JSON.parse(%(["a", "b", "c", "d"]))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("items[1:3]").must_equal(%(["b","c"]))
    evaluator.evaluate("items[:2]").must_equal(%(["a","b"]))
    evaluator.evaluate("items[2:]").must_equal(%(["c","d"]))
  end

  it "re-templates a dotted-access BASE whose Crinja lookup returns nil (not just on a Crinja exception)" do
    # Real bug found benchmarking robertdebock.spamassassin: `vars/
    # main.yml`'s own `spamassassin_service: "{{ _spamassassin_service[
    # ansible_facts['os_family'] ~ '-' ~ ansible_facts[
    # 'distribution_major_version']] | default(...) }}"` stores itself
    # as unrendered `{{ }}` text (a role default computed from a
    # dict-index-with-fallback chain) - `{{ spamassassin_service }}`
    # alone rendered fine (the outer multi-pass re-templating loop in
    # VariableSubstitutor#substitute catches a bare leftover "{{"), but
    # `{{ spamassassin_service.name }}` resolved to the literal string
    # "undefined" instead of "spamassassin". Root cause: the dotted-
    # access dispatch tries Crinja first, and Crinja's own vars are
    # never re-templated - attribute access on the raw `{{ }}` string
    # fails to Crinja's Undefined (not an exception), so `render_via_
    # crinja_value` returned a quiet `nil` - the fallback to `@lookup.
    # nested` (which already had the correct re-templating fix) only
    # ever ran on an actual *exception*, never on this quiet nil.
    v = Hash(String, JSON::Any).new
    v["inner_dict"] = JSON.parse(%({"name":"spamassassin","state":"started"}))
    v["outer_var"] = JSON::Any.new("{{ inner_dict }}")
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("outer_var").must_equal(%({"name":"spamassassin","state":"started"}))
    evaluator.evaluate("outer_var.name").must_equal("spamassassin")
  end

  describe "process-wide dispatch-shape cache (SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #4)" do
    # #split_ternary/#split_ternary_no_else/#boolean_logic? are now
    # memoized by literal expr text in a process-wide (not per-instance)
    # Hash, since which of the 4 dispatch shapes a `{{ }}` body's TEXT
    # has is a pure function of that text. These specs are the "does the
    # shared cache generalize correctly" net: the SAME literal expr
    # string, evaluated by DIFFERENT ExpressionEvaluator instances (each
    # with its own @vars), must still produce each instance's own
    # correct result - a broken cache (e.g. one that accidentally
    # memoized a RESULT instead of just the shape) would show the first
    # instance's answer leaking into the second.
    it "evaluates the same literal ternary text correctly across different ExpressionEvaluator instances/values" do
      first = Krikri::VariableSubstitutor::ExpressionEvaluator.new(Hash(String, JSON::Any){"flag" => JSON::Any.new(true)})
      second = Krikri::VariableSubstitutor::ExpressionEvaluator.new(Hash(String, JSON::Any){"flag" => JSON::Any.new(false)})

      first.evaluate("'yes' if flag else 'no'").must_equal("yes")
      second.evaluate("'yes' if flag else 'no'").must_equal("no")
      # Re-check the first AFTER the second ran, on the identical literal
      # text - a cache keyed on the wrong thing (e.g. a memoized RESULT
      # rather than just "this text has ternary shape") would show the
      # second instance's answer bleeding into the first here.
      first.evaluate("'yes' if flag else 'no'").must_equal("yes")
    end

    it "evaluates the same literal else-less-ternary text correctly across different values" do
      first = Krikri::VariableSubstitutor::ExpressionEvaluator.new(Hash(String, JSON::Any){"flag" => JSON::Any.new(true)})
      second = Krikri::VariableSubstitutor::ExpressionEvaluator.new(Hash(String, JSON::Any){"flag" => JSON::Any.new(false)})

      first.evaluate("'shown' if flag").must_equal("shown")
      second.evaluate("'shown' if flag").must_equal("")
    end

    it "evaluates the same literal boolean-logic text correctly across different values" do
      first = Krikri::VariableSubstitutor::ExpressionEvaluator.new(Hash(String, JSON::Any){"a" => JSON::Any.new(true), "b" => JSON::Any.new(false)})
      second = Krikri::VariableSubstitutor::ExpressionEvaluator.new(Hash(String, JSON::Any){"a" => JSON::Any.new(false), "b" => JSON::Any.new(false)})

      first.evaluate("a or b").must_equal("True")
      second.evaluate("a or b").must_equal("False")
    end

    it "still falls through to the plain evaluator for text that has no top-level ternary/boolean-logic shape at all" do
      # A cached "no match" (nil/false) result is the common case - most
      # `{{ }}` bodies aren't ternaries or boolean-logic expressions -
      # and is exactly the case a naive `||=`-based cache would fail to
      # memoize at all (nil looks like "not cached yet" to `||=`),
      # silently defeating most of the point of caching. Evaluated twice
      # to exercise both the cache-miss (first call) and cache-hit
      # (second call) path for the SAME "no match" text.
      evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(Hash(String, JSON::Any){"x" => JSON::Any.new(5_i64)})
      evaluator.evaluate("x + 1").must_equal("6")
      evaluator.evaluate("x + 1").must_equal("6")
    end
  end

  describe "native-typing indirection comparisons (KNOWN_MISSING.md's narrow one-off fix)" do
    # robertdebock.java/buluma.java's real shape: vars/main.yml maps
    # ansible_distribution to a YAML-int Java version table, indirects
    # it twice, and gates a task on `java_version == 8` - on real
    # ansible-core 2.19 the indirected value stays a native int and the
    # comparison is True; this engine's `{{ }}` substitution preserves
    # the SOURCE type as a string through a bare indirection (see
    # jinja_renderer.cr's own comment on why - protecting a DIFFERENT,
    # already-fixed idiom, buluma.bind's own quoted-string case just
    # below), so `{{ java_version == 8 }}` used to render "False" -
    # wrong, and silently so (no error, no failed task).
    it "treats a bare-indirected variable's underlying YAML int as a real int in ==" do
      v = Hash(String, JSON::Any).new
      v["java_default_version"] = JSON::Any.new(8_i64)
      v["java_version"] = JSON::Any.new("{{ java_default_version }}")
      evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

      evaluator.evaluate("java_version == 8").must_equal("True")
      evaluator.evaluate("java_version != 8").must_equal("False")
    end

    # The narrow fix must not regress the case it was explicitly built
    # around NOT breaking: buluma.bind's own `bind_python_version: "{{
    # bind_default_python_version }}"` where the referenced var is the
    # quoted YAML STRING "3" - `(bind_python_version == '3')` must stay
    # True (Ansible: string stays a string through the
    # indirection, same value on both sides of ==).
    it "still gets buluma.bind's quoted-string indirection idiom right (regression guard)" do
      v = Hash(String, JSON::Any).new
      v["bind_default_python_version"] = JSON::Any.new("3")
      v["bind_python_version"] = JSON::Any.new("{{ bind_default_python_version }}")
      evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

      evaluator.evaluate("bind_python_version == '3'").must_equal("True")
    end

    it "leaves a DIRECT (non-indirected) int/string comparison untouched" do
      v = Hash(String, JSON::Any).new
      v["n"] = JSON::Any.new(8_i64)
      evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

      evaluator.evaluate("n == 8").must_equal("True")
    end
  end

  describe "+ concatenation of a list whose own elements need recursive re-rendering" do
    # Real bug found via a live confirm-phase round against jtyr.motd on
    # a real host: `motd_info: "{{ motd_info__default + motd_info__
    # custom }}"` - `motd_info__default`'s own list items are dicts
    # whose VALUES are each a further `{{ some_fact }}`-style
    # indirection. resolve_plus_operand's plain-lookup fallback
    # (retemplated_lookup_value) only re-rendered a resolved value that
    # was itself a bare String - an Array/Hash containing nested
    # unrendered String values passed straight through unchanged, so
    # the concatenated list kept literal "{{ some_fact }}" text in
    # every dict value instead of the real fact, with no error at all.
    it "re-renders nested template values inside list items resolved through a bare `+` operand" do
      v = Hash(String, JSON::Any).new
      v["hostname_fact"] = JSON::Any.new("myhost")
      v["list_a"] = JSON.parse(%([{"FQDN": "{{ hostname_fact }}"}]))
      v["list_b"] = JSON.parse(%([]))
      evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

      evaluator.evaluate("(list_a + list_b)[0].FQDN").must_equal("myhost")
    end
  end

  describe "+ accumulator appending a DICT literal (`default([]) + [{...}]`)" do
    # Real bug found via round 601558 against diodonfrost.p10k: its
    # `Extract only 'name', 'home' and 'group' fields from users
    # information` task accumulates a fact across loop iterations -
    # `p10k_users_information: "{{ p10k_users_information | default([])
    # + [{'name': item['name'], 'home': item['home'], 'group': item[
    # 'group']}] }}"` - the classic "grow a list of dicts" pattern.
    # resolve_plus_operand_literal (the `+`-operand dispatch) knew
    # quoted/numeric/bool literals and ARRAY literals but never dict
    # literals, so the `{'name': ..., ...}` element fell through to a
    # plain variable-name lookup, which cannot resolve it - every
    # accumulated element silently became null, and the next task's
    # `item['home']` failed with "'item['home']' is undefined". The
    # dict-literal handling already existed for TOP-LEVEL dict
    # expressions (evaluate_dict_literal); it just was never wired into
    # the `+`-operand path.
    it "resolves a dict-literal element inside a `+`-appended list literal to a real dict" do
      v = Hash(String, JSON::Any).new
      v["item"] = JSON.parse(%({"name": "root", "home": "/root", "group": 0}))
      v["p10k_users_information"] = JSON.parse(%([]))
      evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

      rendered = evaluator
        .evaluate("p10k_users_information | default([]) + [{'name': item['name'], 'home': item['home'], 'group': item['group']}]")

      rendered.must_equal(%([{"name":"root","home":"/root","group":0}]))
    end

    it "accumulates a list of dicts across loop iterations holding real dicts, not null" do
      v = Hash(String, JSON::Any).new
      v["p10k_users_register.results"] = JSON.parse(%([
        {"name": "root", "home": "/root", "group": 0},
        {"name": "deploy", "home": "/home/deploy", "group": 1000}
      ]))

      v["p10k_users_information"] = JSON.parse(%([]))
      2.times do |i|
        v["item"] = v["p10k_users_register.results"].as_a[i]
        v["p10k_users_information"] = JSON.parse(Krikri::VariableSubstitutor::ExpressionEvaluator.new(v).evaluate(
          "p10k_users_information | default([]) + [{'name': item['name'], 'home': item['home'], 'group': item['group']}]"
        ))
      end

      evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
      evaluator.evaluate("p10k_users_information[0]['home']").must_equal("/root")
      evaluator.evaluate("p10k_users_information[1]['home']").must_equal("/home/deploy")
      evaluator.evaluate("p10k_users_information[1]['name']").must_equal("deploy")
    end
  end

  # Strict +/- operand classes - Ansible hard-fails the task on
  # every one of these (live-verified against ansible-core 2.19.11 with
  # a minimal `debug: msg: "{{ ... }}"` playbook; exact texts in
  # CRINJA_PHASE2_REPORT.md's strictness section). Before this change
  # both engines silently produced lenient text (the Crinja-first path
  # rendered `Undefined` as "" and None as its "None" repr; the
  # hand-rolled fallback string-concatenated or collapsed to "").
  describe "strict +/- operand classes (raise like Ansible)" do
    private def evaluator
      v = Hash(String, JSON::Any).new
      v["host"] = JSON::Any.new("web1")
      v["port"] = JSON::Any.new(8080_i64)
      v["null_var"] = JSON::Any.new(nil)
      v["list1"] = JSON.parse(%([1, 2]))
      v["d1"] = JSON.parse(%({"a": 1}))
      v["omit_var"] = JSON::Any.new("{{ omit }}")
      evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    end

    it "raises on a genuinely MISSING left operand of `+` (corrects the phase-2 report's match claim)" do
      assert_raises_message(Krikri::PlusMinusOperandError, "'missing_var' is undefined") do
        evaluator.evaluate("missing_var + host")
      end
    end

    it "raises on a genuinely MISSING right operand of `-`" do
      assert_raises_message(Krikri::PlusMinusOperandError, "'missing_var' is undefined") do
        evaluator.evaluate("port - missing_var")
      end
    end

    it "raises on a defined-null LEFT operand of `+`" do
      assert_raises_message(Krikri::PlusMinusOperandError,
        "unsupported operand type(s) for +: 'NoneType' and 'str'") do
        evaluator.evaluate("null_var + host")
      end
    end

    it "raises on a defined-null RIGHT operand of `+` (str-concat wording)" do
      assert_raises_message(Krikri::PlusMinusOperandError,
        %(can only concatenate str (not "NoneType") to str)) do
        evaluator.evaluate("host + null_var")
      end
    end

    it "raises on an `omit` operand of `+` (Ansible's `_OmitType` concat wording, right-hand)" do
      assert_raises_message(Krikri::PlusMinusOperandError,
        %(can only concatenate str (not "_OmitType") to str)) do
        evaluator.evaluate("host + omit")
      end
    end

    it "raises on a var whose own value renders to `omit` (nested sentinel, same wording)" do
      assert_raises_message(Krikri::PlusMinusOperandError,
        %(can only concatenate str (not "_OmitType") to str)) do
        evaluator.evaluate("host + omit_var")
      end
    end

    it "raises on a defined-null operand of `-`" do
      assert_raises_message(Krikri::PlusMinusOperandError,
        "unsupported operand type(s) for -: 'NoneType' and 'str'") do
        evaluator.evaluate("null_var - host")
      end
    end

    it "raises on list + non-list (list concat with int)" do
      assert_raises_message(Krikri::PlusMinusOperandError,
        %(can only concatenate list (not "int") to list)) do
        evaluator.evaluate("list1 + 3")
      end
    end

    it "raises on str + list" do
      assert_raises_message(Krikri::PlusMinusOperandError,
        %(can only concatenate str (not "list") to str)) do
        evaluator.evaluate("host + list1")
      end
    end

    it "raises on dict + dict" do
      assert_raises_message(Krikri::PlusMinusOperandError,
        "unsupported operand type(s) for +: 'dict' and 'dict'") do
        evaluator.evaluate("d1 + d1")
      end
    end

    it "raises on list - non-list (list minus int)" do
      assert_raises_message(Krikri::PlusMinusOperandError,
        "unsupported operand type(s) for -: 'list' and 'int'") do
        evaluator.evaluate("list1 - 3")
      end
    end

    it "raises through the Crinja-first path too (the strict gate runs before Crinja)" do
      # Crinja itself is lenient on every class above (it stringifies
      # Undefined as "", None as its repr, and APPENDS for list + int) -
      # only the pre-Crinja strict gate makes these fail.
      assert_raises(Krikri::PlusMinusOperandError) do
        evaluator.evaluate("host + null_var")
      end
    end
  end

  # Filter precedence inside binary-operator operands: `|` binds TIGHTER
  # than `+`/`-`/`~`/`*`, so each operand's own filter chain applies BEFORE
  # the operator combines - and the operand must reach the combine with its
  # FILTERED type intact (`v|string` on a float var is the string "4.0",
  # not the float the old stringify-then-JSON.parse round trip turned it
  # into). Found via mrlesmithjr.mongodb round 981080:
  # `{{ 'https://x/server-' + v|string + '.asc' }}` hard-failed "can only
  # concatenate str (not \"float\") to str" where Ansible
  # concatenated. All values here live-verified against local
  # ansible-playbook.
  describe "filter precedence inside binary-operator operands" do
    private def evaluator
      v = Hash(String, JSON::Any).new
      v["v"] = JSON::Any.new(4.0)
      v["n"] = JSON::Any.new("2")
      v["lst"] = JSON.parse(%(["A", "B"]))
      v["mtch"] = JSON::Any.new("a+b")
      evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    end

    it "concatenates a filtered float operand as its filtered STRING result" do
      evaluator.evaluate("'a' + v|string").must_equal("a4.0")
      evaluator.evaluate("'https://x/server-' + v|string + '.asc'")
        .must_equal("https://x/server-4.0.asc")
    end

    it "keeps the filtered type through a parenthesized operand too" do
      evaluator.evaluate("'a' + (v|string) + 'b'").must_equal("a4.0b")
    end

    it "adds a filtered numeric operand numerically" do
      evaluator.evaluate("v|int + 1").must_equal("5")
      evaluator.evaluate("1 + v|float").must_equal("5.0")
      evaluator.evaluate("lst|length + 1").must_equal("3")
      evaluator.evaluate("n|int * 3").must_equal("6")
    end

    it "still raises str + int on a FILTERED non-string operand (type comes from the filter, not the var)" do
      assert_raises_message(Krikri::PlusMinusOperandError,
        %(can only concatenate str (not "int") to str)) do
        evaluator.evaluate("'a' + v|int")
      end
    end

    it "tilde-concatenates filtered operands" do
      evaluator.evaluate("'a' ~ v|string ~ 'b'").must_equal("a4.0b")
    end

    it "concatenates a filtered string operand mid-chain" do
      evaluator.evaluate("v|string + 'x'").must_equal("4.0x")
    end

    it "filters with operator-bearing quoted arguments stay intact" do
      evaluator.evaluate("'a+b' | replace('+', '-')").must_equal("a-b")
      evaluator.evaluate("mtch | replace('+', ' AND ')").must_equal("a AND b")
      evaluator.evaluate("x|default('a' + 'b')").must_equal("ab")
    end

    it "fails on an undefined filter-chain operand exactly like Ansible" do
      assert_raises_message(Krikri::PlusMinusOperandError, "'undef_var' is undefined") do
        evaluator.evaluate("'a' + undef_var|string")
      end
    end

    it "still allows an undefined-tolerant first filter to consume the undefined" do
      evaluator.evaluate("'a' + undef_var|default('b')").must_equal("ab")
    end

    it "raises `_OmitType` unsupported-operand wording for omit on the LEFT of `+`" do
      assert_raises_message(Krikri::PlusMinusOperandError,
        "unsupported operand type(s) for +: '_OmitType' and 'str'") do
        evaluator.evaluate("omit + 'a'")
      end
    end

    it "raises `_OmitType` concat wording for omit on the RIGHT of a list `+`" do
      assert_raises_message(Krikri::PlusMinusOperandError,
        %(can only concatenate list (not "_OmitType") to list)) do
        evaluator.evaluate("lst + omit")
      end
    end

    it "raises `_OmitType` unsupported wording for numeric + omit and - omit (both sides)" do
      assert_raises_message(Krikri::PlusMinusOperandError,
        "unsupported operand type(s) for +: 'int' and '_OmitType'") do
        evaluator.evaluate("1 + omit")
      end
      assert_raises_message(Krikri::PlusMinusOperandError,
        "unsupported operand type(s) for -: '_OmitType' and 'int'") do
        evaluator.evaluate("omit - 1")
      end
      assert_raises_message(Krikri::PlusMinusOperandError,
        "unsupported operand type(s) for -: 'int' and '_OmitType'") do
        evaluator.evaluate("1 - omit")
      end
    end
  end

  describe "valid +/- shapes still succeed alongside the strict operand classes" do
    private def evaluator
      v = Hash(String, JSON::Any).new
      v["host"] = JSON::Any.new("web1")
      v["port"] = JSON::Any.new(8080_i64)
      v["list1"] = JSON.parse(%(["a"]))
      v["list2"] = JSON.parse(%(["b"]))
      evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    end

    it "adds int + float numerically through the fallback combine (Jinja parity)" do
      evaluator.evaluate("8080 + 2.5").must_equal("8082.5")
    end

    it "keeps str + str, list + list, and int + int working" do
      evaluator.evaluate("host + '.example.com'").must_equal("web1.example.com")
      evaluator.evaluate("list1 + list2").must_equal(%(["a","b"]))
      evaluator.evaluate("port + 10").must_equal("8090")
    end

    it "keeps `~` LENIENT on a missing operand (deliberate scope boundary: strictness is +/- only)" do
      evaluator.evaluate("missing_var ~ host").must_equal("web1")
    end
  end
end
