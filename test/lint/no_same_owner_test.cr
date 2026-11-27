require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe NoSameOwnerRule do
    private def rule
      NoSameOwnerRule.new
    end

    it "flags synchronize and unarchive without an owner exemption" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: No same owner repro
          hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: Synchronize a config file
              ansible.posix.synchronize:
                src: /etc/hostname
                dest: /tmp/hostname.synced
              when: false

            - name: Extract a tarball
              ansible.builtin.unarchive:
                src: /tmp/archive.tar.gz
                dest: /tmp/extracted
              when: false
        YAML
      v.size.must_equal(2)
      v.map(&.line).must_equal([7, 13])
      v.each do |violation|
        violation.rule_id.must_equal("no-same-owner")
        violation.severity.must_equal(Severity::LOW)
        violation.column.must_equal(0)
        violation.message.must_equal(
          "Do not preserve the owner and group when transferring files across hosts.")
      end
    end

    it "flags a tar unless extra_opts disables owner preservation" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Plain tar
          unarchive:
            src: /a/a.tar
            dest: /b
        - name: Tar gz with list option
          unarchive:
            src: /a/a.tar.gz
            dest: /b
            extra_opts:
              - --no-same-owner
        - name: Tar bz2 with string option
          unarchive:
            src: /a/a.tar.bz2
            dest: /b
            extra_opts: "--no-same-owner"
        - name: Tar xz
          unarchive:
            src: /a/a.tar.xz
            dest: /b
        YAML
      v.map(&.line).must_equal([2, 17])
    end

    it "follows Python's end anchor, which allows one final newline" do
      v = lint_yaml(rule, <<-'YAML')
        ---
        - name: Block scalar src
          unarchive:
            src: |
              /a/a.tar.gz
            dest: /b
        - name: Two final newlines
          unarchive:
            src: "/a/a.tar.gz\n\n"
            dest: /b
        YAML
      v.map(&.line).must_equal([2])
    end

    it "reads extra_opts as a mapping by key, like Python's in" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Mapping tar option
          unarchive:
            src: /a/a.tar.gz
            dest: /b
            extra_opts:
              --no-same-owner: true
        - name: Mapping zip option
          unarchive:
            src: /a/a.zip
            dest: /b
            extra_opts:
              "-X": true
        YAML
      v.map(&.line).must_equal([8])
    end

    it "flags a zip only when extra_opts carries -X" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Zip without -X
          unarchive:
            src: /a/a.zip
            dest: /b
        - name: Zip with -X
          unarchive:
            src: /a/a.zip
            dest: /b
            extra_opts:
              - -X
        - name: Zip with -X and the tar option
          unarchive:
            src: /a/a.zip
            dest: /b
            extra_opts:
              - -X
              - --no-same-owner
        YAML
      v.map(&.line).must_equal([6, 12])
    end

    it "clears synchronize for any explicit delegate_to" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Default owner
          synchronize:
            src: /a
            dest: /b
        - name: Delegated to localhost
          synchronize:
            src: /a
            dest: /b
          delegate_to: localhost
        - name: Delegated elsewhere
          synchronize:
            src: /a
            dest: /b
          delegate_to: otherhost
        - name: Delegated to null
          synchronize:
            src: /a
            dest: /b
          delegate_to: null
        YAML
      v.size.must_equal(1)
      v.first.line.must_equal(2)
    end

    it "takes archive as owner and group's default" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Archive off
          synchronize:
            src: /a
            dest: /b
            archive: false
        - name: Archive off, owner on
          synchronize:
            src: /a
            dest: /b
            archive: false
            owner: root
        - name: Owner off
          synchronize:
            src: /a
            dest: /b
            owner: false
        - name: Both off
          synchronize:
            src: /a
            dest: /b
            owner: false
            group: false
        - name: Quoted false owner
          synchronize:
            src: /a
            dest: /b
            group: "false"
        YAML
      # Upstream defaults owner AND group to archive, so turning only one
      # of them off still leaves the other preserving ownership.
      v.map(&.line).must_equal([7, 13, 24])
    end

    it "skips a remote_src unarchive unless it is delegated to localhost" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Remote src
          unarchive:
            src: /a/a.tar
            dest: /b
            remote_src: true
        - name: Remote src on localhost
          unarchive:
            src: /a/a.tar
            dest: /b
            remote_src: true
          delegate_to: localhost
        - name: Remote src off
          unarchive:
            src: /a/a.tar
            dest: /b
            remote_src: false
        YAML
      v.map(&.line).must_equal([7, 13])
    end

    it "reads src only as a string and merges args into the parameters" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Integer src
          unarchive:
            src: 123
            dest: /b
        - name: Owner from args
          synchronize:
            src: /a
            dest: /b
          args:
            owner: root
        - name: Option from args
          unarchive:
            src: /a/a.tar
            dest: /b
          args:
            extra_opts:
              - --no-same-owner
        YAML
      v.size.must_equal(1)
      v.first.line.must_equal(6)
    end

    it "matches only upstream's module spellings" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Legacy unarchive
          ansible.legacy.unarchive:
            src: /a/a.tar
            dest: /b
        - name: Posix synchronize
          ansible.posix.synchronize:
            src: /a
            dest: /b
        - name: Legacy synchronize
          ansible.legacy.synchronize:
            src: /a
            dest: /b
        YAML
      v.map(&.line).must_equal([6])
    end

    it "is registered for --list-rules as an opt-in LOW rule" do
      registered = RuleRegistry.default.find("no-same-owner")
      raise "no-same-owner is not registered" unless registered
      registered.severity.must_equal(Severity::LOW)
      registered.tags.must_equal(["opt-in"])
      Profile.of("no-same-owner").must_be_nil
    end

    private def run(yaml : String, config : LintConfig) : Array(Violation)
      path = File.tempname("no-same-owner", ".yml")
      File.write(path, yaml)
      registry = RuleRegistry.new([rule] of Rule)
      Runner.new(registry, config).run([path])
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    it "stays off until the enable list names it" do
      yaml = "---\n- hosts: all\n  tasks:\n    - synchronize:\n        src: /a\n        dest: /b\n"
      run(yaml, LintConfig.new).must_be_empty
      run(yaml, LintConfig.new(enable_list: ["no-same-owner"])).size.must_equal(1)
    end

    it "suppresses a violation from a noqa anywhere in the task body" do
      yaml = "---\n- hosts: all\n  tasks:\n    - name: t\n      synchronize:\n" \
             "        src: /a\n        dest: /b\n      # noqa: no-same-owner\n"
      run(yaml, LintConfig.new(enable_list: ["no-same-owner"])).must_be_empty
    end
  end
end
