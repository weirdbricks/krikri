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
