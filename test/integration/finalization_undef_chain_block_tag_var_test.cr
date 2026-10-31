require "../minitest_helper"
require "file_utils"

# issue #418: the fourth "<<< caused by >>>" stanza (the bare "'x' is
# undefined" with its Origin at the failing definition) was suppressed when
# that definition's own value is a full Jinja template mixing `{{ }}` spans
# with `{% %}` block tags - andrewrothstein.openjdk's openjdk_install_subdir
# bottoms out at 'openjdk_app' is undefined inside a `{% if openjdk_app ==
# "jre" %}` tag. Real 2.19.11 still points the stanza's Origin at that
# definition's value token and shortens the third chain level to the key
# prefix.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "task-arg undef-chain stanza for a block-tag var definition" do
  it "emits the stanza when the failing var's own value carries {% if %} tags" do
    tempdir = File.tempname("undef-chain-blocktag").tap { |dir| Dir.mkdir(dir) }
    role = File.join(tempdir, "roles", "blocktagrole")
    FileUtils.mkdir_p(File.join(role, "tasks"))
    FileUtils.mkdir_p(File.join(role, "vars"))
    FileUtils.mkdir_p(File.join(role, "defaults"))
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - blocktagrole
      YAML
    defaults_file = File.join(role, "defaults", "main.yml")
    File.write(defaults_file, <<-YAML)
      blocktag_ver:
        major: 16
        minor: 0
        patch: 1
        b: 9
      blocktag_parent_dir: /tmp/blocktag-parent
      YAML
    vars_file = File.join(role, "vars", "main.yml")
    File.write(vars_file, <<-YAML)
      blocktag_install_dir: '{{ blocktag_parent_dir }}/openjdk'
      blocktag_install_subdir: '{{ blocktag_install_dir }}/{% if blocktag_app == "jre" %}-jre{% endif %}'
      YAML
    tasks_file = File.join(role, "tasks", "main.yml")
    File.write(tasks_file, <<-YAML)
      - stat:
          path: '{{ blocktag_install_subdir }}'
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    # The stanza appears exactly once, Origin'd at the failing
    # definition's value token (the quote after blocktag_install_subdir:),
    # and the third chain level shortens to the key prefix - the inner
    # message moves entirely into the stanza.
    stanza = "'blocktag_app' is undefined\nOrigin: #{File.expand_path(vars_file)}:2:26\n\n" \
             "1 blocktag_install_dir: '{{ blocktag_parent_dir }}/openjdk'\n" \
             "2 blocktag_install_subdir: '{{ blocktag_install_dir }}/{% if blocktag_app == \"jre\" %}-jre{% endif %}'\n" \
             "                           ^ column 26\n\n"
    text.scan(stanza).size.must_equal(1, text)
    text.must_include("Error while resolving value for 'path'.\nOrigin: #{File.expand_path(tasks_file)}:2:11")
    text.wont_include("Error while resolving value for 'path': 'blocktag_app' is undefined\nOrigin: ")
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end
end
