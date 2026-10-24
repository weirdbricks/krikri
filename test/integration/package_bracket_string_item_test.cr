require "../minitest_helper"
require "file_utils"

# Issue #300 executor side (wangsha.ansible_role_lynis, round 29880205):
# the whole loop -> substitute_task_params -> package-plugin chain. A
# with_items entry "{% if false %}lynis{% else %}[]{% endif %}" renders to
# the STRING "[]" and ansible fails `package: name: "{{ item }}"` through
# dnf with "No package [] available." (rc 1), while a real empty-LIST name
# stays a "Nothing to do" no-op - both arrive on the plugin wire as the
# text "[]", so the executor must carry the template's STRING result
# marked (NON_STRING_PARAM_PREFIX) for the plugin to tell the two apart.
# Drives the real binary against fake dnf/yum/rpm shims on PATH (the
# `use: dnf` task option pins the backend; the plugin's shell commands
# find the shims), so no real package manager is touched.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "looped package name rendered as the string '[]'" do
  it "fails through the backend like ansible (marked) and no-ops the unmarked shapes" do
    shim_dir = PluginSpecHelper.tmp_path("fake-dnf")
    Dir.mkdir_p(shim_dir)
    invoked_log = File.join(shim_dir, "invoked.log")
    File.write("#{shim_dir}/dnf", <<-SH
      #!/bin/sh
      printf 'dnf\n' >> #{invoked_log}
      printf '%s\n' "$@" >> #{invoked_log}
      echo "Last metadata expiration check: 0:01:10 ago on Sat Sep 19 13:26:53 2026."
      echo "No match for argument: []"
      echo "Error: Unable to find a match: []" >&2
      exit 1
      SH
    )
    File.write("#{shim_dir}/yum", <<-SH
      #!/bin/sh
      printf 'yum' >> #{invoked_log}
      printf '%s\n' "$@" >> #{invoked_log}
      exit 1
      SH
    )
    File.write("#{shim_dir}/rpm", <<-SH
      #!/bin/sh
      printf 'rpm' >> #{invoked_log}
      printf '%s\n' "$@" >> #{invoked_log}
      exit 1
      SH
    )
    {"dnf", "yum", "rpm"}.each { |name| File.chmod("#{shim_dir}/#{name}", 0o755) }

    playbook = File.tempname("package-bracket-string", ".yml")
    File.write(playbook, <<-YAML
      - hosts: localhost
        gather_facts: false
        connection: local
        vars:
          removed: []
        tasks:
          - name: real empty list var
            package:
              name: "{{ removed }}"
              use: dnf
              state: present
          - name: plain bracket literal
            package:
              name: "[]"
              use: dnf
              state: present
          - name: block-rendered string item
            package:
              name: "{{ item }}"
              use: dnf
              state: present
            with_items:
              - "{% if false %}lynis{% else %}[]{% endif %}"
      YAML
    )

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook],
      output: output, error: output, input: IO::Memory.new,
      env: {"PATH" => "#{shim_dir}:#{ENV["PATH"]}"})
    text = output.to_s

    # ansible (live, round 29880205) reports the string item through the
    # backend's own failure shape; both unmarked shapes (the real empty
    # LIST var and the plain bracket LITERAL, no templating involved) are
    # the ok no-ops.
    status.success?.must_equal(false, text)
    text.includes?("failed: [localhost] (item=[])").must_equal(true, text)
    text.includes?("\"msg\": \"Failed to install some of the specified packages\"").must_equal(true, text)
    text.includes?("\"failures\": [\"No package [] available.\"]").must_equal(true, text)
    text.scan("ok: [localhost]").size.must_equal(2)

    # The literal str reached dnf as its own argv element.
    commands = File.exists?(invoked_log) ? File.read(invoked_log) : ""
    commands.includes?("dnf\ninstall").must_equal(true, commands)
    commands.includes?("\n[]\n").must_equal(true, commands)
  ensure
    FileUtils.rm_r(shim_dir) if shim_dir
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
