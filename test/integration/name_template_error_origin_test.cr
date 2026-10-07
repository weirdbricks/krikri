require "../minitest_helper"
require "file_utils"

# The `[WARNING]: Encountered N template error(s).` blocks behind a task
# NAME's marker render, byte-compared against ansible-core 2.19.11:
#
# - the Origin points at the DEFINING site of the failing value - the
#   task's own file (role tasks file or include_tasks: target included)
#   for a direct `{{ undefined }}`, but a nested variable's own
#   definition site (role vars/defaults, play vars, the inventory line,
#   a `-e` extra var, a role param's playbook entry) once the render
#   recurses into it. Previously the locator only ever scanned the
#   PLAYBOOK file, so a role-file task printed no warning block at all
#   (andrewrothstein.nats, round 2300765).
# - the error counter is shared across the nested templating contexts of
#   one name render and restarts per task; a nested MULTI-part value's
#   context completes (and numbers its errors) before the enclosing
#   context's own errors, while a nested SINGLE-expression value's
#   failure joins the enclosing context in occurrence order.
# - inventory-line origins print WITHOUT a column and underline the
#   whole line; `-e` origins print `Origin: <CLI option '-e'>` with the
#   raw value excerpted and no caret.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "task name template error warning blocks" do
  it "points a role task's direct name error at the role tasks file" do
    src_dir = File.tempname("name-warn-role-task")
    Dir.mkdir_p(File.join(src_dir, "roles", "e2", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "e2", "defaults"))
    File.write(File.join(src_dir, "roles", "e2", "tasks", "main.yml"), <<-YAML)
      ---
      - name: Direct {{ undef_direct }} here
        ansible.builtin.debug:
          msg: hi
      - name: Via default {{ dv }}
        ansible.builtin.debug:
          msg: hi
      YAML
    File.write(File.join(src_dir, "roles", "e2", "defaults", "main.yml"), <<-YAML)
      dv: "{{ undef_dv }}"
      YAML
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - e2
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: src_dir)

    stderr = output.to_s
    # Byte-identical to real 2.19.11: value-token column (9 = right after
    # `- name: `), 2 context lines, caret under the value start.
    stderr.must_include("error 1 - 'undef_direct' is undefined\nOrigin: #{File.expand_path(File.join(src_dir, "roles", "e2", "tasks", "main.yml"))}:2:9\n\n1 ---\n2 - name: Direct {{ undef_direct }} here\n          ^ column 9\n\n")
    # The role's defaults file is the origin for a var it defines.
    stderr.must_include("error 1 - 'undef_dv' is undefined\nOrigin: #{File.expand_path(File.join(src_dir, "roles", "e2", "defaults", "main.yml"))}:1:5\n\n1 dv: \"{{ undef_dv }}\"\n      ^ column 5\n\n")
    # Numbering restarts per task.
    stderr.must_include("[WARNING]: Encountered 1 template error.")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "points an included file task's name error at the included file" do
    src_dir = File.tempname("name-warn-included")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "inc.yml"), <<-YAML)
      ---
      - name: In inc {{ undef_inc }}
        ansible.builtin.debug:
          msg: hi
      YAML
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - ansible.builtin.include_tasks: inc.yml
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: src_dir)

    output.to_s.must_include("error 1 - 'undef_inc' is undefined\nOrigin: #{File.expand_path(File.join(src_dir, "inc.yml"))}:2:9")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "splits a nested var chain into per-defining-file blocks with real's numbering (nats)" do
    src_dir = File.tempname("name-warn-nats")
    Dir.mkdir_p(File.join(src_dir, "roles", "wb", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "wb", "vars"))
    File.write(File.join(src_dir, "roles", "wb", "vars", "main.yml"), <<-YAML)
      ---
      nats_install_dir: "{{ nats_parent_install_dir }}/{{ nats_name }}"
      nats_name: "{{ nats_app }}-{{ nats_ver }}-{{ nats_platform }}"
      nats_platform: linux-amd64
      YAML
    File.write(File.join(src_dir, "roles", "wb", "tasks", "main.yml"), <<-YAML)
      - name: Look for nats app in {{ nats_install_dir }}
        ansible.builtin.debug:
          msg: hello
      YAML
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - wb
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: src_dir)

    text = output.to_s
    vars_path = File.expand_path(File.join(src_dir, "roles", "wb", "vars", "main.yml"))
    # Two blocks, in real's order: the nats_name context's errors first
    # (numbered 1,2 - it completes before its enclosing context), then
    # the nats_install_dir context's own error (3). Real excerpts each
    # block at the failing value's own line.
    text.must_include("[WARNING]: Encountered 2 template errors.\nerror 1 - 'nats_app' is undefined\nerror 2 - 'nats_ver' is undefined\nOrigin: #{vars_path}:3:12\n\n1 ---\n2 nats_install_dir: \"{{ nats_parent_install_dir }}/{{ nats_name }}\"\n3 nats_name: \"{{ nats_app }}-{{ nats_ver }}-{{ nats_platform }}\"\n             ^ column 12\n\n")
    text.must_include("[WARNING]: Encountered 1 template error.\nerror 3 - 'nats_parent_install_dir' is undefined\nOrigin: #{vars_path}:2:19\n\n1 ---\n2 nats_install_dir: \"{{ nats_parent_install_dir }}/{{ nats_name }}\"\n                    ^ column 19\n\n")
    # The banner's marker numbers match the blocks (3 before 1,2).
    text.must_include("TASK [wb : Look for nats app in << error 3 - 'nats_parent_install_dir' is undefined >>/<< error 1 - 'nats_app' is undefined >>-<< error 2 - 'nats_ver' is undefined >>-linux-amd64]")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "numbers a direct name error before a play-var single-expression error" do
    src_dir = File.tempname("name-warn-play-vars")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          playv: "{{ undef_pv }}"
        tasks:
          - name: N {{ v1 }} P {{ playv }}
            ansible.builtin.debug:
              msg: hi
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: src_dir)

    text = output.to_s
    # Occurrence order across both origins: the name-level error (1,
    # name value column 13) then the play var's own definition (2, value
    # column 12 = the quote). A single-expression nested value joins the
    # enclosing context instead of opening its own.
    text.must_include("error 1 - 'v1' is undefined\nOrigin: #{File.expand_path(File.join(src_dir, "pb.yml"))}:7:13")
    text.must_include("error 2 - 'undef_pv' is undefined\nOrigin: #{File.expand_path(File.join(src_dir, "pb.yml"))}:5:12")
    text.must_include("TASK [N << error 1 - 'v1' is undefined >> P << error 2 - 'undef_pv' is undefined >>]")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "points an inventory var error at the inventory line with a full-line caret" do
    src_dir = File.tempname("name-warn-inventory")
    Dir.mkdir_p(src_dir)
    inv = File.join(src_dir, "hosts.ini")
    File.write(inv, <<-INI)
      localhost ansible_connection=local invv="{{ undef_inv }}"
      INI
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: use {{ invv }}
            ansible.builtin.debug:
              msg: hi
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", inv, "pb.yml"], output: output, error: output, chdir: src_dir)

    # Real prints no column for an inventory origin and underlines the
    # whole line (verified against 2.19.11, including the 2-digit-line
    # label width).
    line = "localhost ansible_connection=local invv=\"{{ undef_inv }}\""
    output.to_s.must_include("error 1 - 'undef_inv' is undefined\nOrigin: #{File.expand_path(inv)}:1\n\n1 #{line}\n  #{"^" * line.size}\n\n")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "labels an extra-var error Origin: <CLI option '-e'>" do
    src_dir = File.tempname("name-warn-extra-vars")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: use {{ ev }}
            ansible.builtin.debug:
              msg: hi
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, "-e", %({"ev": "{{ undef_ev }}"}), "pb.yml"], output: output, error: output, chdir: src_dir)

    output.to_s.must_include("error 1 - 'undef_ev' is undefined\nOrigin: <CLI option '-e'>\n\n{{ undef_ev }}\n\n")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "points a role param error at the playbook roles: entry" do
    src_dir = File.tempname("name-warn-role-param")
    Dir.mkdir_p(File.join(src_dir, "roles", "e9", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "e9", "vars"))
    File.write(File.join(src_dir, "roles", "e9", "vars", "main.yml"), <<-YAML)
      rp2: "{{ undef_rp2 }}"
      YAML
    File.write(File.join(src_dir, "roles", "e9", "tasks", "main.yml"), <<-YAML)
      - name: use {{ rp }} and {{ rp2 }}
        ansible.builtin.debug:
          msg: hi
      YAML
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - role: e9
            vars:
              rp: "{{ undef_rp }}"
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: src_dir)

    text = output.to_s
    text.must_include("error 1 - 'undef_rp' is undefined\nOrigin: #{File.expand_path(File.join(src_dir, "pb.yml"))}:7:13")
    text.must_include("error 2 - 'undef_rp2' is undefined\nOrigin: #{File.expand_path(File.join(src_dir, "roles", "e9", "vars", "main.yml"))}:1:6")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "dedups identical blocks across repeated tasks" do
    src_dir = File.tempname("name-warn-dedup")
    Dir.mkdir_p(src_dir)
    inv = File.join(src_dir, "hosts.ini")
    File.write(inv, <<-INI)
      localhost2 ansible_connection=local invv2="{{ undef_inv2 }}"
      INI
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost2
        connection: local
        gather_facts: false
        tasks:
          - name: use {{ invv2 }}
            ansible.builtin.debug:
              msg: hi
          - name: use {{ invv2 }}
            ansible.builtin.debug:
              msg: hi
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", inv, "pb.yml"], output: output, error: output, chdir: src_dir)

    text = output.to_s
    text.must_include("error 1 - 'undef_inv2' is undefined")
    # Identical warning text displays once, like real's Display.warning
    # dedup (verified: the second identical task prints no block).
    text.scan("Origin: #{File.expand_path(inv)}:1").size.must_equal(1)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "points a block vars error at the block's vars entry, not the task line" do
    src_dir = File.tempname("name-warn-block-vars")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - block:
              - name: B {{ bv }}
                ansible.builtin.debug:
                  msg: hi
            vars:
              bv: "{{ undef_bv }}"
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: src_dir)

    # Real points the Origin at the block's own `vars:` value, not at
    # the nested task's name line (verified byte-for-byte against
    # 2.19.11 with this exact layout).
    output.to_s.must_include("error 1 - 'undef_bv' is undefined\nOrigin: #{File.expand_path(File.join(src_dir, "pb.yml"))}:10:13\n\n 8             msg: hi\n 9       vars:\n10         bv: \"{{ undef_bv }}\"\n               ^ column 13\n\n")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "points an include_vars value error at the included file" do
    src_dir = File.tempname("name-warn-include-vars")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "iv.yml"), <<-YAML)
      ivv: "{{ undef_ivv }}"
      YAML
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - ansible.builtin.include_vars:
              file: iv.yml
          - name: V {{ ivv }}
            ansible.builtin.debug:
              msg: hi
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: src_dir)

    output.to_s.must_include("error 1 - 'undef_ivv' is undefined\nOrigin: #{File.expand_path(File.join(src_dir, "iv.yml"))}:1:6\n\n1 ivv: \"{{ undef_ivv }}\"\n       ^ column 6\n\n")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "points an -e @file value error at the file's value position" do
    src_dir = File.tempname("name-warn-extra-file")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "extra.yml"), <<-YAML)
      evf: "{{ undef_evf }}"
      YAML
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: X {{ evf }}
            ansible.builtin.debug:
              msg: hi
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, "-e", "@extra.yml", "pb.yml"], output: output, error: output, chdir: src_dir)

    # NOT `Origin: <CLI option '-e'>` - the file's own value position,
    # with the usual excerpt + caret (verified against 2.19.11).
    output.to_s.must_include("error 1 - 'undef_evf' is undefined\nOrigin: #{File.expand_path(File.join(src_dir, "extra.yml"))}:1:6\n\n1 evf: \"{{ undef_evf }}\"\n       ^ column 6\n\n")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "renders a k=v extra var containing spaces and reports the CLI origin" do
    src_dir = File.tempname("name-warn-extra-kv")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: E {{ ev }}
            ansible.builtin.debug:
              msg: hi
      YAML

    output = IO::Memory.new
    # The whitespace split is split_args-aware: the value's jinja2 block
    # survives the space (real renders the chain, erroring on
    # undef_ev), rather than truncating the value at the first space.
    Process.run(BINARY, ["-i", INVENTORY, "-e", "ev={{ undef_ev }}", "pb.yml"], output: output, error: output, chdir: src_dir)

    output.to_s.must_include("error 1 - 'undef_ev' is undefined\nOrigin: <CLI option '-e'>\n\n{{ undef_ev }}\n\n")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "points an include_role vars error at the playbook's vars entry and keeps the written action in the banner" do
    src_dir = File.tempname("name-warn-include-role-vars")
    Dir.mkdir_p(File.join(src_dir, "roles", "ic", "tasks"))
    File.write(File.join(src_dir, "roles", "ic", "tasks", "main.yml"), <<-YAML)
      - name: C {{ icv }}
        ansible.builtin.debug:
          msg: hi
      YAML
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - ansible.builtin.include_role:
              name: ic
            vars:
              icv: "{{ undef_icv }}"
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: src_dir)

    text = output.to_s
    # The include itself succeeds; the CHILD task's name render carries
    # the marker, with the Origin at the playbook's vars: entry
    # (site.yml line 8, value column 14).
    text.must_include("error 1 - 'undef_icv' is undefined\nOrigin: #{File.expand_path(File.join(src_dir, "pb.yml"))}:8:14\n\n6         name: ic\n7       vars:\n8         icv: \"{{ undef_icv }}\"\n               ^ column 14\n\n")
    # An unnamed include_role's banner keeps the action AS WRITTEN
    # (real: "TASK [ansible.builtin.include_role : ic]").
    text.must_include("TASK [ansible.builtin.include_role : ic] ")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "points an import_role vars error at the playbook's vars entry" do
    src_dir = File.tempname("name-warn-import-role-vars")
    Dir.mkdir_p(File.join(src_dir, "roles", "ir", "tasks"))
    File.write(File.join(src_dir, "roles", "ir", "tasks", "main.yml"), <<-YAML)
      - name: Q {{ irq }}
        ansible.builtin.debug:
          msg: hi
      YAML
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - ansible.builtin.import_role:
              name: ir
            vars:
              irq: "{{ undef_irq }}"
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: src_dir)

    output.to_s.must_include("error 1 - 'undef_irq' is undefined\nOrigin: #{File.expand_path(File.join(src_dir, "pb.yml"))}:8:14\n\n6         name: ir\n7       vars:\n8         irq: \"{{ undef_irq }}\"\n               ^ column 14\n\n")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "treats a handler whose name fails to template as unusable (warning + not-found abort, no error block)" do
    src_dir = File.tempname("name-warn-handler-unusable")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          hv2: "{{ undef_hv2 }}"
        tasks:
          - name: trigger
            ansible.builtin.debug:
              msg: hi
            changed_when: true
            notify: h1
        handlers:
          - name: HH {{ hv2 }}
            ansible.builtin.debug:
              msg: ran
      YAML

    stdout_io = IO::Memory.new
    stderr_io = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: stdout_io, error: stderr_io, chdir: src_dir)

    # Real never runs the handler: the unusable-name warning (not the
    # task-name template-error block) plus the not-found abort, both on
    # STDERR; rc=1; no recap.
    stderr_io.to_s.must_equal("[WARNING]: Handler 'HH {{ hv2 }}' is unusable because it has no listen topics and the name could not be templated (host-specific variables are not supported in handler names). The error: 'undef_hv2' is undefined\n[ERROR]: The requested handler 'h1' was not found in either the main handlers list nor in the listening handlers list\n")
    refute(stdout_io.to_s.includes?("RUNNING HANDLER"))
    refute(stdout_io.to_s.includes?("Origin:"))
    status.exit_code.must_equal 1
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "treats a handler name referencing a HOST var as unusable (host vars are not in scope)" do
    src_dir = File.tempname("name-warn-handler-hostvar")
    Dir.mkdir_p(File.join(src_dir, "inv", "host_vars"))
    File.write(File.join(src_dir, "inv", "hosts.ini"), "localhost ansible_connection=local\n")
    File.write(File.join(src_dir, "inv", "host_vars", "localhost.yml"), <<-YAML)
      hfail: "{{ undef_hf }}"
      YAML
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: trigger
            ansible.builtin.debug:
              msg: hi
            changed_when: true
            notify: h1
        handlers:
          - name: HH {{ hfail }}
            ansible.builtin.debug:
              msg: ran
      YAML

    stderr_io = IO::Memory.new
    stdout_io = IO::Memory.new
    Process.run(BINARY, ["-i", File.join(src_dir, "inv", "hosts.ini"), "pb.yml"], output: stdout_io, error: stderr_io, chdir: src_dir)

    # Live-verified vs 2.19.11: handler-name templating sees NO
    # host-scoped variables at all, so even a resolvable host var makes
    # the handler unusable.
    stderr_io.to_s.must_include("Handler 'HH {{ hfail }}' is unusable because it has no listen topics and the name could not be templated (host-specific variables are not supported in handler names). The error: 'hfail' is undefined")
    stderr_io.to_s.must_include("[ERROR]: The requested handler 'h1' was not found in either the main handlers list nor in the listening handlers list")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "numbers a later nested multi-part context before the enclosing context's errors" do
    src_dir = File.tempname("name-warn-context-order")
    Dir.mkdir_p(File.join(src_dir, "roles", "e11", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "e11", "vars"))
    File.write(File.join(src_dir, "roles", "e11", "vars", "main.yml"), <<-YAML)
      dx: "{{ undef_d }} {{ ex }} {{ mx }}"
      ex: "{{ undef_e }}"
      mx: "{{ undef_m }} tail"
      YAML
    File.write(File.join(src_dir, "roles", "e11", "tasks", "main.yml"), <<-YAML)
      - name: use {{ dx }}
        ansible.builtin.debug:
          msg: hi
      YAML
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - e11
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: src_dir)

    text = output.to_s
    # mx's multi-part context completes mid-render and numbers its error
    # first; dx's own collected errors follow in occurrence order
    # (verified byte-identical against 2.19.11, banner included).
    text.must_include("error 1 - 'undef_m' is undefined")
    text.must_include("error 2 - 'undef_d' is undefined")
    text.must_include("error 3 - 'undef_e' is undefined")
    text.must_include("TASK [e11 : use << error 2 - 'undef_d' is undefined >> << error 3 - 'undef_e' is undefined >> << error 1 - 'undef_m' is undefined >> tail]")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
