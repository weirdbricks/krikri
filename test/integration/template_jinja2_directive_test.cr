require "file_utils"
require "../minitest_helper"

# A template's leading `#jinja2:` directive line goes through Ansible's
# ast.literal_eval + TemplateOverrides dataclass type validation, so a
# QUOTED string where a bool is required fails the task outright:
#
#   [ERROR]: Task failed: Syntax error in template:
#   TemplateOverrides.trim_blocks must be <class 'bool'> instead of
#   <class 'str'>
#   ...
#   <<< caused by >>>
#   Syntax error in template: <same>
#   Origin: <the template file>
#
# found via apolloclark.packetbeat's packetbeat-6.6.yml (round 1500121),
# whose `#jinja2: trim_blocks: "true", lstrip_blocks: "true"` header made
# ansible-playbook fail while this engine coerced the string leniently
# and passed.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_directive_playbook(header_line : String)
  src = File.tempname("directive-src", ".j2")
  dest = File.tempname("directive-dest")
  playbook = File.tempname("directive", ".yml")
  File.write(src, "#{header_line}\nhello {{ greeting }}\n")
  File.write(playbook, <<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      vars:
        greeting: hi
      tasks:
        - name: Copy config file
          ansible.builtin.template:
            src: #{src}
            dest: #{dest}
    YAML

  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
  File.delete(src) if src && File.exists?(src)
  File.delete(dest) if dest && File.exists?(dest)
end

describe "template #jinja2: directive value validation" do
  it "fails a quoted bool with TemplateOverrides' own type error and the template-file Origin" do
    status, output = run_directive_playbook(%(#jinja2: trim_blocks: "true"))

    status.exit_code.must_equal(2)
    error_text = "Syntax error in template: TemplateOverrides.trim_blocks must be <class 'bool'> instead of <class 'str'>"
    output.must_include("[ERROR]: Task failed: #{error_text}")
    output.must_include("<<< caused by >>>")
    output.must_include("#{error_text}\nOrigin: ")
    output.must_include("\"msg\": \"Task failed: #{error_text}\"")
    output.wont_include("Unhandled exception")
  end

  it "reports a non-string wrong-typed value with its own Python type name" do
    status, output = run_directive_playbook("#jinja2: trim_blocks: 1")

    status.exit_code.must_equal(2)
    output.must_include("TemplateOverrides.trim_blocks must be <class 'bool'> instead of <class 'int'>")
  end

  it "still accepts a real Python bool literal" do
    status, output = run_directive_playbook("#jinja2: trim_blocks: True")

    status.exit_code.must_equal(0)
    output.wont_include("TemplateOverrides")
  end
end
