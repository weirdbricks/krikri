require "file_utils"
require "../spec_helper"

# Real Ansible loads ALL of a play's roles - and their vars/main.yml and
# defaults/main.yml - into the variable manager when the play is SET UP,
# not when each role's tasks reach the front of the queue. So a role can
# see the vars of a role that runs AFTER it. This engine scoped them to
# the owning role (and, since 0.9.599, its dependents), so such a
# reference resolved to nothing - which is what made geerlingguy.php's
# own `when: php_packages is not defined` run a task real Ansible skips
# (`php_packages` lives in buluma.php/vars/main.yml, a role that runs
# later in the same dependency chain). Found round 183.
#
# The precedence this establishes was mapped against ansible-core 2.19.4
# with a three-way matrix rather than assumed, and every case below is
# one of its cells. Low to high:
#
#   all roles' defaults < this role's own defaults < play vars
#     < all roles' vars < this role's own vars
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def role_dir(root : String, name : String) : String
  dir = File.join(root, "roles", name)
  Dir.mkdir_p(File.join(dir, "tasks"))
  dir
end

private def write_role(root : String, name : String,
                       tasks : String, defaults : String? = nil,
                       vars : String? = nil, meta : String? = nil)
  dir = role_dir(root, name)
  File.write(File.join(dir, "tasks", "main.yml"), tasks)
  {"defaults" => defaults, "vars" => vars, "meta" => meta}.each do |sub, body|
    next unless body
    Dir.mkdir_p(File.join(dir, sub))
    File.write(File.join(dir, sub, "main.yml"), body)
  end
end

private def run_play(root : String, playbook : String) : String
  File.write(File.join(root, "inv.ini"), "localhost ansible_connection=local\n")
  File.write(File.join(root, "pb.yml"), playbook)
  io = IO::Memory.new
  Process.run(BINARY, ["-i", "inv.ini", "pb.yml"], output: io, error: io, chdir: root)
  io.to_s
end

private def with_root(&)
  root = File.tempname("rolescope")
  Dir.mkdir_p(root)
  yield root
ensure
  FileUtils.rm_rf(root) if root && Dir.exists?(root)
end

describe "cross-role variable scope" do
  it "lets an EARLIER role see a later role's vars and defaults" do
    with_root do |root|
      write_role(root, "first", <<-YAML)
        - name: first
          ansible.builtin.debug:
            msg: "v={{ second_role_var | default('UNDEF') }} d={{ second_role_default | default('UNDEF') }}"
        YAML
      write_role(root, "second",
        tasks: "- {name: second, ansible.builtin.debug: {msg: second}}\n",
        vars: "second_role_var: from_vars\n",
        defaults: "second_role_default: from_defaults\n")

      output = run_play(root, <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          roles: [first, second]
        YAML

      output.should contain("v=from_vars d=from_defaults")
    end
  end

  it "gives the EXECUTING role's own defaults precedence over another role's" do
    with_root do |root|
      write_role(root, "alpha",
        tasks: "- {name: alpha, ansible.builtin.debug: {msg: \"sd={{ shared_default }}\"}}\n",
        defaults: "shared_default: alpha_default\n")
      write_role(root, "beta",
        tasks: "- {name: beta, ansible.builtin.debug: {msg: \"sd={{ shared_default }}\"}}\n",
        defaults: "shared_default: beta_default\n")

      output = run_play(root, <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          roles: [alpha, beta]
          post_tasks:
            - name: outside
              ansible.builtin.debug:
                msg: "outside={{ shared_default }}"
        YAML

      # Each role sees its own; a task outside any role sees the LAST
      # role's - so the two defaults layers cannot be one flat merge.
      output.should contain("sd=alpha_default")
      output.should contain("sd=beta_default")
      output.should contain("outside=beta_default")
    end
  end

  it "ranks ANY role's vars above ANY role's defaults, own or not" do
    with_root do |root|
      write_role(root, "alpha",
        tasks: "- {name: alpha, ansible.builtin.debug: {msg: \"x={{ x_name }} y={{ y_name }}\"}}\n",
        defaults: "x_name: alpha_DEFAULT\n",
        vars: "y_name: alpha_VAR\n")
      write_role(root, "beta",
        tasks: "- {name: beta, ansible.builtin.debug: {msg: beta}}\n",
        defaults: "y_name: beta_DEFAULT\n",
        vars: "x_name: beta_VAR\n")

      output = run_play(root, <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          roles: [alpha, beta]
        YAML

      # alpha's OWN default loses to beta's var; alpha's OWN var beats
      # beta's default. So "own role wins" is not the rule - the
      # vars/defaults split outranks it.
      output.should contain("x=beta_VAR y=alpha_VAR")
    end
  end

  it "puts play vars above another role's defaults and below another role's vars" do
    with_root do |root|
      write_role(root, "alpha",
        tasks: "- {name: alpha, ansible.builtin.debug: {msg: \"d={{ p_vs_default }} v={{ p_vs_var }}\"}}\n")
      write_role(root, "beta",
        tasks: "- {name: beta, ansible.builtin.debug: {msg: beta}}\n",
        defaults: "p_vs_default: beta_DEFAULT\n",
        vars: "p_vs_var: beta_VAR\n")

      output = run_play(root, <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          vars:
            p_vs_default: FROM_PLAY
            p_vs_var: FROM_PLAY
          roles: [alpha, beta]
        YAML

      output.should contain("d=FROM_PLAY v=beta_VAR")
    end
  end

  it "carries through a meta/main.yml dependency chain - the motivating case" do
    with_root do |root|
      write_role(root, "top",
        tasks: "- {name: top, ansible.builtin.debug: {msg: top}}\n",
        meta: "dependencies:\n  - depa\n  - depb\n")
      write_role(root, "depa", <<-YAML)
        - name: depa gated
          ansible.builtin.debug:
            msg: would define pkg_list
          when: pkg_list is not defined
        YAML
      write_role(root, "depb",
        tasks: "- {name: depb, ansible.builtin.debug: {msg: depb}}\n",
        vars: "pkg_list: from_depb_vars\n")

      output = run_play(root, <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          roles: [top]
        YAML

      # depa runs BEFORE depb, and must still see depb's vars - exactly
      # geerlingguy.php's `when: php_packages is not defined` against
      # buluma.php/vars/main.yml.
      output.should contain("skipping")
      output.should_not contain("would define pkg_list")
    end
  end

  it "ranks a REGISTERED variable above the role's own vars of the same name" do
    # Real Ansible's precedence puts registered vars (19) well above role
    # vars (15). This engine applied role vars with a blind overwrite, so
    # a task registering into a name its own role's vars/main.yml also
    # defines lost the command's output entirely - verified against
    # ansible-core 2.19.4, which resolves to the registered result.
    with_root do |root|
      write_role(root, "rv",
        tasks: <<-YAML,
        - name: register into a colliding name
          ansible.builtin.command: echo from_register
          register: collide_reg
        - name: who wins
          ansible.builtin.debug:
            msg: "reg={{ collide_reg.stdout | default(collide_reg) }}"
        YAML
        vars: "collide_reg: from_role_vars\n")

      output = run_play(root, <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          roles: [rv]
        YAML

      output.should contain("reg=from_register")
    end
  end

  it "does NOT expose an include_role:'d role's vars to the rest of the play" do
    with_root do |root|
      write_role(root, "incl",
        tasks: "- {name: incl, ansible.builtin.debug: {msg: incl}}\n",
        vars: "incl_var: from_include_role\n",
        defaults: "incl_default: from_include_role\n")

      output = run_play(root, <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - ansible.builtin.include_role:
                name: incl
            - name: after
              ansible.builtin.debug:
                msg: "after={{ incl_var | default('UNDEF') }} d={{ incl_default | default('UNDEF') }}"
        YAML

      # Real Ansible instantiates roles: at play setup; include_role: is
      # dynamic and keeps its vars scoped unless `public: true`, so the
      # play-wide layers must take only STATIC roles.
      output.should contain("after=UNDEF d=UNDEF")
    end
  end
end
