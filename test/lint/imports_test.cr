require "../minitest_helper"
require "file_utils"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  # The file set krikri-lint reports must match the one ansible-lint
  # walks: a playbook pulls in its imported task files, imported playbooks
  # and role content, transitively.
  describe Imports do
    serial!

    private def write(root : String, path : String, content : String) : String
      full = File.join(root, path)
      Dir.mkdir_p(File.dirname(full))
      File.write(full, content)
      full
    end

    # A playbook exercising every inclusion form krikri-lint resolves.
    PLAY = "---\n- name: Main\n  hosts: localhost\n  roles:\n    - myrole\n  tasks:\n" \
           "    - ansible.builtin.import_tasks: tasks/one.yml\n" \
           "    - ansible.builtin.include_tasks:\n        file: tasks/two.yml\n" \
           "    - ansible.builtin.include_role:\n        name: myrole\n" \
           "    - name: Block\n      block:\n" \
           "        - ansible.builtin.include_tasks: tasks/nested.yml\n" \
           "      rescue:\n" \
           "        - ansible.builtin.include_tasks: tasks/two.yml\n" \
           "- ansible.builtin.import_playbook: other/child.yml\n"

    private def fixture : String
      root = File.tempname("lintimports")
      write(root, "play.yml", PLAY)
      write(root, "tasks/one.yml", "---\n- name: One\n  ansible.builtin.command: echo one\n")
      write(root, "tasks/two.yml", "---\n- name: Two\n  ansible.builtin.command: echo two\n")
      write(root, "tasks/nested.yml", "---\n- name: Nested\n  ansible.builtin.command: echo n\n")
      write(root, "roles/myrole/tasks/main.yml", "---\n- name: Role\n  ansible.builtin.command: echo r\n")
      write(root, "roles/myrole/handlers/main.yml", "---\n- name: H\n  ansible.builtin.command: echo h\n")
      write(root, "roles/myrole/defaults/main.yml", "---\nmyrole_var: 1\n")
      write(root, "other/child.yml", "---\n- name: Child\n  hosts: localhost\n  tasks: []\n")
      root
    end

    it "pulls in imported task files, roles and imported playbooks" do
      root = fixture
      begin
        found = Imports.expand([File.join(root, "play.yml")])
        found.map { |path| path.sub(root + "/", "") }.must_equal([
          "play.yml",
          "roles/myrole/tasks/main.yml",
          "roles/myrole/handlers/main.yml",
          "roles/myrole/defaults/main.yml",
          "tasks/one.yml",
          "tasks/two.yml",
          "tasks/nested.yml",
          "other/child.yml",
        ])
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "walks imports transitively, even from an included file" do
      root = File.tempname("lintimports")
      write(root, "top.yml", "---\n- name: P\n  hosts: all\n  tasks:\n" \
                             "    - ansible.builtin.include_tasks: mid/mid.yml\n")
      write(root, "mid/mid.yml", "---\n- ansible.builtin.include_tasks: leaf.yml\n")
      write(root, "mid/leaf.yml", "---\n- name: Leaf\n  ansible.builtin.command: echo leaf\n")
      begin
        Imports.expand([File.join(root, "top.yml")]).map { |path| path.sub(root + "/", "") }
          .must_equal(["top.yml", "mid/mid.yml", "mid/leaf.yml"])
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "reads the old include syntax and drops its key=value tokens" do
      root = File.tempname("lintimports")
      write(root, "top.yml", "---\n- name: P\n  hosts: all\n  tasks:\n" \
                             "    - include: tasks/one.yml tags=always\n")
      write(root, "tasks/one.yml", "---\n- name: One\n  ansible.builtin.command: echo one\n")
      begin
        Imports.expand([File.join(root, "top.yml")]).map { |path| path.sub(root + "/", "") }
          .must_equal(["top.yml", "tasks/one.yml"])
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "skips a templated import, which cannot be resolved statically" do
      root = File.tempname("lintimports")
      write(root, "top.yml", "---\n- name: P\n  hosts: all\n  tasks:\n" \
                             "    - ansible.builtin.include_tasks: \"{{ which }}.yml\"\n")
      begin
        Imports.expand([File.join(root, "top.yml")]).map { |path| path.sub(root + "/", "") }
          .must_equal(["top.yml"])
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "skips a missing import rather than inventing a file" do
      root = File.tempname("lintimports")
      write(root, "top.yml", "---\n- name: P\n  hosts: all\n  tasks:\n" \
                             "    - ansible.builtin.import_tasks: gone.yml\n")
      begin
        Imports.expand([File.join(root, "top.yml")]).map { |path| path.sub(root + "/", "") }
          .must_equal(["top.yml"])
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "leaves a file listed twice alone" do
      root = File.tempname("lintimports")
      write(root, "top.yml", "---\n- name: P\n  hosts: all\n  tasks:\n" \
                             "    - ansible.builtin.import_tasks: one.yml\n" \
                             "    - ansible.builtin.include_tasks: one.yml\n")
      write(root, "one.yml", "---\n- name: One\n  ansible.builtin.command: echo one\n")
      begin
        found = Imports.expand([File.join(root, "top.yml"), File.join(root, "one.yml")])
        found.map { |path| path.sub(root + "/", "") }.must_equal(["top.yml", "one.yml"])
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "does not walk a handlers or vars file for further imports" do
      root = File.tempname("lintimports")
      write(root, "handlers/main.yml", "---\n- name: H\n  ansible.builtin.command: echo h\n")
      begin
        Imports.children(File.join(root, "handlers/main.yml")).must_be_empty
      ensure
        FileUtils.rm_rf(root)
      end
    end

    # Imports.expand resolves the default roles path from THIS process's
    # HOME, so the override cannot go to a child, and ENV_MUTEX is not
    # enough - a non-serial test keeps reading HOME through the window
    # (issue #1191). Quiesce the process instead.
    describe "role installed under a substituted HOME" do
      exclusive!

      it "does not lint a role installed under ~/.ansible/roles" do
        # ansible-galaxy's default install location is third-party content,
        # not the project being linted: upstream resolves it (its _rolepath
        # searches the default roles path) but its runner drops lintables
        # outside the project, so an installed role's files never get
        # linted or counted. HOME is pointed at a scratch tree so the
        # candidate really exists, making the skip observable.
        root = File.tempname("lintimports")
        fake_home = File.join(root, "home")
        write(fake_home, ".ansible/roles/installedrole/tasks/main.yml",
          "---\n- name: R\n  ansible.builtin.command: echo r\n")
        write(root, "play.yml", "---\n- name: P\n  hosts: all\n  tasks:\n" \
                                "    - ansible.builtin.include_role:\n        name: installedrole\n")
        previous = ENV["HOME"]?
        begin
          ENV["HOME"] = fake_home
          Imports.expand([File.join(root, "play.yml")]).map { |path| path.sub(root + "/", "") }
            .must_equal(["play.yml"])
        ensure
          if previous
            ENV["HOME"] = previous
          else
            ENV.delete("HOME")
          end
          FileUtils.rm_rf(root)
        end
      end
    end

    it "resolves symlinked role paths to their real location, like upstream" do
      root = File.tempname("lintimports")
      write(root, "real_role/tasks/main.yml", "---\n- name: R\n  ansible.builtin.command: echo r\n")
      Dir.mkdir(File.join(root, "roles"))
      File.symlink("../real_role", File.join(root, "roles", "role"))
      begin
        found = Imports.expand([File.join(root, "roles/role/tasks/main.yml")])
        found.map { |path| path.sub(root + "/", "") }.must_equal(
          ["real_role/tasks/main.yml"])
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end
end
