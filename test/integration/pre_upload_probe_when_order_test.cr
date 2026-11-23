require "../minitest_helper"
require "file_utils"

# Issue #1745: the eager pre-upload probe evaluated a task's `when:` while
# it decided whether the host really dials, so the clause's warning and
# deprecation output surfaced ahead of the task's banner (even ahead of the
# PLAY banner for a play's first task). A corpus replay cannot see this -
# it compares stdout followed by stderr, where a block printed too early
# still lands in the right stream - so the ORDER across the two streams is
# asserted here from merged output.
private PROBE_ORDER_BINARY = File.expand_path("../../bin/krikri-playbook", __DIR__)
private PROBE_ORDER_PATH   = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

private def run_probe_order_case(playbook_yaml : String) : String
  dir = PluginSpecHelper.tmp_path("probe-when-order-#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(File.join(dir, "home"))
  # The same dead-endpoint shape the unreachable divergence cases use: the
  # interpreter pin keeps ansible's discovery exec from becoming the first
  # ssh usage, and the stub transport makes the connection fail.
  File.write(File.join(dir, "inventory.ini"), <<-INI)
target ansible_connection=ssh ansible_host=192.0.2.1 ansible_user=root ansible_python_interpreter=/usr/bin/python3 ansible_ssh_executable=./always-fail
INI
  File.write(File.join(dir, "always-fail"), <<-SH)
#!/bin/sh
echo "Connection to 192.0.2.1 closed by remote host." >&2
exit 255
SH
  File.chmod(File.join(dir, "always-fail"), 0o755)
  File.write(File.join(dir, "playbook.yml"), playbook_yaml)

  output = IO::Memory.new
  Process.run(
    PROBE_ORDER_BINARY,
    ["-i", "inventory.ini", "playbook.yml"],
    output: output,
    error: output,
    chdir: dir,
    env: {
      "ANSIBLE_NOCOLOR"                 => "1",
      "ANSIBLE_PIPELINING"              => "False",
      "HOME"                            => File.join(dir, "home"),
      "PATH"                            => PROBE_ORDER_PATH,
      "ANSIBLE_GATHERING"               => nil,
      "ANSIBLE_CACHE_PLUGIN"            => nil,
      "ANSIBLE_CACHE_PLUGIN_CONNECTION" => nil,
    },
  )
  output.to_s
end

describe "pre-upload probe when: output ordering" do
  it "prints a booked host's deprecation block after the task banner and before its unreachable report" do
    output = run_probe_order_case(<<-YAML)
      - hosts: target
        gather_facts: false
        tasks:
          - ping:
            when: vars is defined
      YAML

    output.must_include("TASK [ping]")
    output.must_include(%([DEPRECATION WARNING]: The internal "vars" dictionary is deprecated.))
    output.must_include("fatal: [target]: UNREACHABLE!")
    banner = output.index!("TASK [ping]")
    block = output.index!(%([DEPRECATION WARNING]: The internal "vars" dictionary is deprecated.))
    fatal = output.index!("fatal: [target]: UNREACHABLE!")

    (banner < block).must_equal(true)
    (block < fatal).must_equal(true)
  end

  it "prints a deferred when:'s literal warning after the task banner, before its fatal" do
    output = run_probe_order_case(<<-YAML)
      - hosts: target
        gather_facts: false
        tasks:
          - ping:
            when: foo == "{{ bar }}"
      YAML

    output.must_include("TASK [ping]")
    output.must_include("[WARNING]: Jinja constant strings should not contain embedded templates.")
    output.must_include("fatal: [target]:")
    banner = output.index!("TASK [ping]")
    warning = output.index!("[WARNING]: Jinja constant strings should not contain embedded templates.")
    fatal = output.index!("fatal: [target]:")

    (banner < warning).must_equal(true)
    (warning < fatal).must_equal(true)
  end
end
