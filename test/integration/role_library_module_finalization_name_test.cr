require "../minitest_helper"
require "file_utils"

# A bare module name a role's own `library/` serves resolves as a legacy
# FILE plugin BEFORE any collection redirect is consulted, and a legacy
# resolution has no collection to name: ansible's task-args finalization
# error (ansible-core 2.19+, Task#_post_validate_args' resolved_fqcn)
# then reports the name exactly as written, not the collection FQCN the
# same bare name redirects to on a host without the role-local module
# (issue #1140: superlumic.superlumic-osx-defaults ships
# library/osx_defaults and its finalization failure says 'osx_defaults';
# live-captured against ansible-core 2.21 - without the role-local file
# the identical task reports 'community.general.osx_defaults').
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_role_playbook(role_name : String, with_library_module : Bool)
  tempdir = File.tempname("role-lib-finalization").tap { |dir| Dir.mkdir(dir) }
  role = File.join(tempdir, "roles", role_name)
  FileUtils.mkdir_p(File.join(role, "tasks"))
  if with_library_module
    FileUtils.mkdir_p(File.join(role, "library"))
    # The module never executes (the task fails at arg templating), the
    # file's mere existence is what steers the resolution.
    File.write(File.join(role, "library", "osx_defaults"), "#!/usr/bin/python\n# stub\n")
  end
  playbook = File.join(tempdir, "site.yml")
  File.write(playbook, <<-YAML)
    - hosts: localhost
      gather_facts: false
      roles:
        - #{role_name}
    YAML
  File.write(File.join(role, "tasks", "main.yml"), <<-YAML)
    - osx_defaults:
        domain: "{{ __libmod_undef_domain }}"
        key: foo
        state: present
    - name: sentinel
      ansible.builtin.debug:
        msg: SHOULD-RUN-AFTER
    YAML
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  FileUtils.rm_rf(tempdir) if tempdir
end

describe "role library module finalization error name" do
  it "names a bare role-served module as written, not its redirect FQCN" do
    status, text = run_role_playbook("libmodrole", with_library_module: true)

    status.exit_code.must_equal(2)
    text.must_include("Finalization of task args for 'osx_defaults' failed: Error while resolving value for 'domain': '__libmod_undef_domain' is undefined")
    text.must_include(%("msg": "Task failed: Finalization of task args for 'osx_defaults' failed:))
    # The redirect to the collection FQCN must not leak into the message.
    text.wont_include("community.general.osx_defaults")
    text.wont_include("SHOULD-RUN-AFTER")
    text.must_match(/failed=1/)
  end

  it "still names the redirect FQCN when no role library serves the bare name" do
    status, text = run_role_playbook("nolibmodrole", with_library_module: false)

    status.exit_code.must_equal(2)
    text.must_include("Finalization of task args for 'community.general.osx_defaults' failed: Error while resolving value for 'domain': '__libmod_undef_domain' is undefined")
    text.wont_include("SHOULD-RUN-AFTER")
    text.must_match(/failed=1/)
  end
end
