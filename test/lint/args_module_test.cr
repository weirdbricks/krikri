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
        "(allow-downgrade, allow-downgrades, allow-unauthenticated, " \
        "allow_downgrades, default-release, install-recommends, name, pkg, " \
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

    it "validates community modules the spec table covers" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Unnamed docker container
          community.docker.docker_container:
            whatever: 1
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal("missing required arguments: name")
    end

    # Regression: issue #1015 - the rule validated only a hand-maintained
    # set of core specs, so every module data/argspecs.json covers but
    # that set did not (dnf5 and all community modules among them) went
    # unvalidated, and non-bool type conversions never failed at all.
    it "flags an invalid state choice on a module the generated table covers" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Bad dnf5 state
          ansible.builtin.dnf5:
            name: sl
            state: bogus-state
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal(
        "value of state must be one of: absent, installed, latest, present, removed, got: bogus-state"
      )
    end

    it "flags an unsupported parameter with the sorted alias tail" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Bad dnf5 param
          ansible.builtin.dnf5:
            name: sl
            use_backend: dnf5
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal(
        "Unsupported parameters for (basic.py) module: use_backend. " \
        "Supported parameters include: allow_downgrade, allowerasing, " \
        "auto_install_module_deps, autoremove, best, bugfix, cacheonly, " \
        "conf_file, disable_excludes, disable_gpg_check, disable_plugin, " \
        "disablerepo, download_dir, download_only, enable_plugin, " \
        "enablerepo, exclude, install_weak_deps, installroot, list, " \
        "lock_timeout, name, nobest, releasever, security, skip_broken, " \
        "sslverify, state, update_cache, update_only, validate_certs " \
        "(expire-cache, pkg)."
      )
    end

    it "flags a null value a list-typed option cannot convert" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Null name
          ansible.builtin.dnf5:
            state: present
            name:
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal(
        "argument 'name' is of type NoneType and we were unable to " \
        "convert to list: <class 'NoneType'> cannot be converted to a list"
      )
    end

    it "flags a string an int-typed option cannot convert" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Bad timeout
          community.docker.docker_compose_v2:
            project_src: /tmp/x
            timeout: banana
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal(
        %(argument 'timeout' is of type str and we were unable to convert to int: "'banana'" cannot be converted to an int)
      )
    end

    it "flags required_one_of on a community module" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Alternative without path
          community.general.alternatives:
            name: krikri-alt
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal("one of the following is required: path, family")
    end

    it "stays silent on mutually exclusive parameters, like upstream" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Name and list together
          ansible.builtin.dnf5:
            name: sl
            list: sl
        YAML
      v.must_be_empty
    end
  end
end
