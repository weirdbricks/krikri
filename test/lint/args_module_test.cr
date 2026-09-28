require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe ArgsModuleRule do
    private def rule
      ArgsModuleRule.new
    end

    it "flags unsupported parameters and lists the alias tail" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Bad param
          ansible.builtin.apt:
            bogus_param: 1
            state: present
        YAML
      v.size.must_equal(1)
      v.first.rule_id.must_equal("args[module]")
      v.first.message.must_equal(
        "Unsupported parameters for (basic.py) module: bogus_param. " \
        "Supported parameters include: allow_change_held_packages, " \
        "allow_downgrade, allow_unauthenticated, auto_install_module_deps, " \
        "autoclean, autoremove, cache_valid_time, clean, deb, " \
        "default_release, dpkg_options, fail_on_autoremove, force, " \
        "force_apt_get, install_recommends, lock_timeout, only_upgrade, " \
        "package, policy_rc_d, purge, state, update_cache, " \
        "update_cache_retries, update_cache_retry_max_delay, upgrade " \
        "(name, pkg, default-release, install-recommends, allow-downgrade, " \
        "allow_downgrades, allow-downgrades, allow-unauthenticated, " \
        "update-cache)."
      )
      v.first.line.must_equal(2)
      v.first.column.must_equal(0)
    end

    it "accepts documented aliases" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Alias ok
          ansible.builtin.apt:
            pkg: x
        YAML
      v.must_be_empty
    end

    it "flags an invalid choices value" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Bad choice
          apt:
            name: x
            state: installed
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal(
        "value of state must be one of: absent, build-dep, fixed, latest, present, got: installed"
      )
    end

    it "flags a non-boolean value for a bool argument" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Bad bool
          ansible.builtin.apt:
            name: x
            update_cache: maybe
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal(
        "argument 'update_cache' is of type str and we were unable to " \
        "convert to bool: The value 'maybe' is not a valid boolean. " \
        "Valid booleans include: 0, 1, 'no', 'on', 'yes', '1', 'false', " \
        "'n', '0', 'y', 'f', 't', 'off', 'true'"
      )
    end

    it "flags missing required arguments" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Missing required
          ansible.builtin.dpkg_selections:
            selection: install
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal("missing required arguments: name")
    end

    it "flags required_together violations" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Required together
          ansible.builtin.debconf:
            name: x
            question: q
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal("parameters are required together: question, vtype, value")
    end

    it "flags missing parameters required by another parameter" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Required by
          ansible.builtin.systemd:
            state: restarted
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal("missing parameter(s) required by 'state': name")
    end

    it "flags required_one_of violations" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: One of
          ansible.builtin.pip:
            state: present
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal("one of the following is required: name, requirements")
    end

    it "flags list_choices violations" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: List choices
          ansible.builtin.deb822_repository:
            name: x
            types:
              - rpm
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal(
        "value of types must be one or more of: deb, deb-src. Got no match for: rpm"
      )
    end

    it "flags missing required arguments on an empty action block" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: No params at all
          ansible.builtin.getent:
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal("missing required arguments: database")
    end

    it "flags required_if violations (any and all semantics)" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: No url source
          ansible.builtin.yum_repository:
            name: x
            description: desc
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal(
        "state is present but any of the following are missing: baseurl, mirrorlist, metalink"
      )

      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Missing description
          ansible.builtin.yum_repository:
            name: x
            baseurl: http://x
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal("state is present but all of the following are missing: description")
    end

    it "does not flag required_if when state is not the trigger value" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Absent repo
          ansible.builtin.yum_repository:
            name: x
            state: absent
        YAML
      v.must_be_empty
    end

    it "remaps a plain YAML boolean into a unique boolean choice" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Upgrade true
          apt:
            upgrade: true
        YAML
      v.must_be_empty

      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Upgrade bogus
          apt:
            upgrade: bogus
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal(
        "value of upgrade must be one of: dist, full, no, safe, yes, got: bogus"
      )
    end

    it "skips templated values in choices and booleans" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Templated
          ansible.builtin.apt:
            name: x
            state: "{{ st }}"
            update_cache: "{{ uc }}"
        YAML
      v.must_be_empty
    end

    it "ignores modules without a spec" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Unspecified module
          community.docker.docker_container:
            whatever: 1
        YAML
      v.must_be_empty
    end
  end
end
