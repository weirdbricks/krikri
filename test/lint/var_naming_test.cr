require "../minitest_helper"
require "../../src/krikri_lint/lint"

# Runs one rule against a real file inside a temp role directory (the
# no-role-prefix role name comes from the roles/<name>/ path).
def lint_role_file(rule : Krikri::Lint::Rule, yaml : String, subdir : String = "defaults") : Array(Krikri::Lint::Violation)
  role_dir = File.tempname("roleprefix")
  Dir.mkdir_p(File.join(role_dir, "roles", "testrole", subdir))
  path = File.join(role_dir, "roles", "testrole", subdir, "main.yml")
  File.write(path, yaml)
  file = Krikri::Lint::PositionedFile.load(path)
  violations = [] of Krikri::Lint::Violation
  rule.check(file, violations)
  violations
ensure
  `rm -rf #{role_dir}` if role_dir
end

module Krikri::Lint
  describe VarNamingRule do
    private def rule
      VarNamingRule.new
    end

    it "flags bad pattern in play vars" do
      v = lint_yaml(rule, <<-YAML, FileType::PLAYBOOK)
        ---
        - hosts: all
          vars:
            myBadVar: 1
          tasks:
            - name: Ok
              command: true
        YAML
      v.map(&.rule_id).must_equal(["var-naming[pattern]"])
      v.first.line.must_equal(4)
    end

    it "flags set_fact keys" do
      v = lint_yaml(rule, <<-YAML, FileType::PLAYBOOK)
        ---
        - hosts: all
          tasks:
            - name: Set
              set_fact:
                badCamel: 1
        YAML
      v.map(&.rule_id).must_equal(["var-naming[pattern]"])
      v.first.message.must_include("(set_fact: badCamel)")
    end

    it "skips private __keys and cacheable in set_fact" do
      v = lint_yaml(rule, <<-YAML, FileType::PLAYBOOK)
        ---
        - hosts: all
          tasks:
            - name: Set
              set_fact:
                __private: 1
                cacheable: true
                good_var: 2
        YAML
      v.must_be_empty
    end

    it "flags reserved names" do
      v = lint_yaml(rule, <<-YAML, FileType::PLAYBOOK)
        ---
        - hosts: all
          vars:
            environment: production
          tasks:
            - name: Ok
              command: true
        YAML
      v.map(&.rule_id).must_equal(["var-naming[no-reserved]"])
    end

    it "allows special ansible_ names" do
      v = lint_yaml(rule, <<-YAML, FileType::PLAYBOOK)
        ---
        - hosts: all
          vars:
            ansible_host: web1
          tasks:
            - name: Ok
              command: true
        YAML
      v.must_be_empty
    end

    it "allows jinja-templated set_fact keys" do
      v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n    - name: Set\n      set_fact:\n        \"loop_fact_{{ item }}\": 1\n", FileType::PLAYBOOK)
      v.must_be_empty
    end

    it "checks vars-file top-level keys" do
      v = lint_yaml(rule, "---\nbadVar: 1\ngood_var: 2\n", FileType::VARS)
      v.size.must_equal(1)
      v.first.line.must_equal(2)
    end

    it "checks register" do
      v = lint_yaml(rule, <<-YAML, FileType::PLAYBOOK)
        ---
        - hosts: all
          tasks:
            - name: Reg
              command: true
              register: badRegister
        YAML
      v.map(&.rule_id).must_equal(["var-naming[pattern]"])
      v.first.message.must_include("(register: badRegister)")
    end

    describe "no-role-prefix" do
      it "flags role defaults/vars keys without the role prefix" do
        v = lint_role_file(rule, <<-YAML)
          ---
          port: 1
          good_port: 2
          _private: 3
          testrole_ok: 4
          YAML
        v.map(&.rule_id).must_equal(["var-naming[no-reserved]", "var-naming[no-role-prefix]", "var-naming[no-role-prefix]"])
        v[1].line.must_equal(3)
        v[1].message.must_equal("Variables names from within roles should use testrole_ as a prefix. (vars: good_port)")
        v[2].message.must_include("(vars: _private)")
      end

      it "applies pattern before no-role-prefix in role vars files" do
        v = lint_role_file(rule, "---\nbadCamel: 1\n", "vars")
        v.map(&.rule_id).must_equal(["var-naming[pattern]"])
      end

      it "checks keys on playbook roles entries" do
        v = lint_yaml(rule, <<-YAML, FileType::PLAYBOOK)
          ---
          - name: P
            hosts: all
            roles:
              - role: nginx
                nginx_ok: 1
                port: 80
                badvar: 2
                vars:
                  path: 1
                  nginx_ok2: 2
          YAML
        v.map(&.rule_id).must_equal(["var-naming[no-role-prefix]", "var-naming[no-role-prefix]"])
        v[0].line.must_equal(8)
        v[1].line.must_equal(10)
        v[1].message.must_include("(vars: path)")
      end

      it "skips pattern and prefix checks for FQCN role entries" do
        v = lint_yaml(rule, "---\n- hosts: all\n  roles:\n    - role: community.docker.docker\n      anything_else: 1\n", FileType::PLAYBOOK)
        v.must_be_empty
      end

      it "skips string-form roles" do
        v = lint_yaml(rule, "---\n- hosts: all\n  roles:\n    - nginx\n", FileType::PLAYBOOK)
        v.must_be_empty
      end

      it "prefix-checks vars on include_role tasks only" do
        v = lint_yaml(rule, <<-YAML, FileType::PLAYBOOK)
          ---
          - hosts: all
            tasks:
              - name: Include
                include_role:
                  name: otherrole
                vars:
                  bar: 1
                  otherrole_ok: 2
              - name: Set
                set_fact:
                  barefact: 1
                register: regout
          YAML
        v.map(&.rule_id).must_equal(["var-naming[no-role-prefix]"])
        v.first.line.must_equal(8)
        v.first.message.must_equal("Variables names from within roles should use otherrole_ as a prefix. (vars: bar)")
      end

      it "skips prefix checks for FQCN and templated include_role names" do
        v = lint_yaml(rule, <<-YAML, FileType::PLAYBOOK)
          ---
          - hosts: all
            tasks:
              - name: A
                include_role:
                  name: community.docker.docker
                vars:
                  anything: 1
              - name: B
                include_role:
                  name: "{{ role_name }}"
                vars:
                  anything: 2
          YAML
        v.must_be_empty
      end
    end
  end
end
