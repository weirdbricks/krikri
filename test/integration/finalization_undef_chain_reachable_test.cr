require "../minitest_helper"
require "file_utils"

# issue #36: the fourth "<<< caused by >>>" stanza (the bare "'x' is
# undefined" message with its Origin at the DEFINITION whose own value
# failed) was suppressed when MORE THAN ONE var layer failed with the
# same message - real 2.19.11 only follows the vars actually reachable
# from the failing arg (msg -> jail_name -> jail_net_ip here), so an
# unrelated role var that also mentions jail_net_ip (and fails with the
# same message) doesn't make the origin ambiguous. The Origin must point
# at jail_name's role-defaults line, not at the unreachable var's file.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "task-arg undef-chain stanza with multiple failing vars" do
  it "emits the stanza through the vars reachable from the failing arg only" do
    tempdir = File.tempname("undef-chain-reach").tap { |dir| Dir.mkdir(dir) }
    role = File.join(tempdir, "roles", "chainrole")
    FileUtils.mkdir_p(File.join(role, "tasks"))
    FileUtils.mkdir_p(File.join(role, "vars"))
    FileUtils.mkdir_p(File.join(role, "defaults"))
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - chainrole
      YAML
    defaults_file = File.join(role, "defaults", "main.yml")
    File.write(defaults_file, <<-YAML)
      jail_domain: 'darkcity'
      jail_net_if: em0
      jail_name: '{{ jail_net_ip }}'
      YAML
    vars_file = File.join(role, "vars", "main.yml")
    File.write(vars_file, <<-YAML)
      ifconfig_net_if_line: 'x{{ jail_net_if }}{{ jail_net_ip }}'
      YAML
    tasks_file = File.join(role, "tasks", "main.yml")
    File.write(tasks_file, <<-YAML)
      - debug: msg='Running tasks for jail {{ jail_name }}'
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    # Two var layers fail with "'jail_net_ip' is undefined" (jail_name in
    # defaults, ifconfig_net_if_line in role vars), but only jail_name is
    # reachable from the msg param - so the stanza appears exactly once,
    # pointing at jail_name's definition.
    stanza = "'jail_net_ip' is undefined\nOrigin: #{File.expand_path(defaults_file)}:3:12\n\n1 jail_domain: 'darkcity'\n2 jail_net_if: em0\n3 jail_name: '{{ jail_net_ip }}'\n             ^ column 12\n\n"
    text.scan(stanza).size.must_equal(1, text)
    # the unreachable sibling's definition must not be mistaken for the origin
    text.wont_include("Origin: #{File.expand_path(vars_file)}")
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end
end
