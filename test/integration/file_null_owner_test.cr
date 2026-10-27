require "file_utils"
require "../minitest_helper"

# `file:` with a NULL `owner:`/`group:` - a YAML null arriving either as a
# bare `owner:` or as a whole-span `owner: "{{ nullvar }}"` whose variable
# holds a null. Every expectation below was probed against ansible-playbook
# 2.19.11 under -c local.
#
# Ansible's basic.py only skips the chown/chgrp when the param is None, so
# a null owner is "not requested" and the lookup never runs - unlike an
# empty string, which IS a requested owner and fails the user lookup
# ("chown failed: failed to look up user "). The wire is strings-only: the
# executor's sentinel demotes to "" on the plugin side, and the plugin's
# #requested_attr restores the None-ness via #explicit_null_param?.
private FILE_NULL_OWNER_ROOT = File.expand_path("../..", __DIR__)
private FILE_NULL_OWNER_BIN  = File.join(FILE_NULL_OWNER_ROOT, "bin", "krikri-playbook")
private FILE_NULL_OWNER_INV  = File.join(FILE_NULL_OWNER_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_file_null_owner_playbook(dirname : String, owner_line : String) : {String, String}
  scratch = PluginSpecHelper.tmp_path("file-null-owner", dirname)
  FileUtils.mkdir_p(scratch)
  playbook = File.join(scratch, "play.yml")
  File.write(playbook, "- hosts: localhost\n  connection: local\n  gather_facts: false\n  vars:\n    nullvar:\n  tasks:\n    - file:\n        path: #{File.join(scratch, dirname)}\n        state: directory\n#{owner_line}\n")
  output = IO::Memory.new
  Process.run(FILE_NULL_OWNER_BIN, ["-i", FILE_NULL_OWNER_INV, playbook], output: output, error: output, chdir: scratch)
  {output.to_s, File.join(scratch, dirname)}
end

describe "file: null owner/group is not requested" do
  it "creates a directory with a whole-span null owner template" do
    # A whole-span template that resolves to null must behave exactly like
    # a bare `owner:` - Ansible skips the chown and the task succeeds.
    output, dir = run_file_null_owner_playbook("dir-null-owner", %(        owner: "{{ nullvar }}"))

    output.wont_include("failed to look up user")
    output.wont_include("FAILED")
    File.directory?(dir).must_equal(true)
  end

  it "creates a directory with a bare null owner" do
    output, dir = run_file_null_owner_playbook("dir-bare-null", "        owner:")

    output.wont_include("failed to look up user")
    output.wont_include("FAILED")
    File.directory?(dir).must_equal(true)
  end

  it "still fails the lookup for an explicit empty-string owner" do
    # The contrast that must keep working: "" is a *requested* owner (not
    # None), so Ansible tries the user lookup and fails with the bare
    # chown message - the null must not be demoted into this behaviour.
    output, dir = run_file_null_owner_playbook("dir-empty-owner", <<-YAML)
            owner: ""
          ignore_errors: true
    YAML

    output.must_include("failed to look up user")
    # Both engines mkdir each missing component BEFORE applying owner to
    # it, so the failed lookup still leaves the directory on disk - the
    # failure is about the chown, not the creation.
    File.directory?(dir).must_equal(true)
  end
end
