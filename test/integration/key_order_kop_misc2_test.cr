require "../minitest_helper"

require "http/server"
require "digest/sha1"
require "digest/md5"

# Round 994002 (kop_misc2 probe role): registered-result key ORDER (and
# key set / value types) pinned for the plugins the round diverged on,
# observed the way the round observed them - `{{ r | to_json }}` on a
# registered task, dumped through copy: (the -v display sorts keys, so
# the order is only observable programmatically; see
# key_order_sweep_test.cr for the general method).
#
# Real references are the cold_py.out capture of the probe role
# (testing/keyorder_probes/kop_misc2) run by ansible-core 2.19.11 on a
# fresh Ubuntu 22.04 host:
# - community.docker.current_container_facts: ansible_facts, failed,
#   changed (exit_json(ansible_facts=...) with no changed);
# - community.libvirt.virt_net command results: exit_json(**{command:
#   value}) with no changed - registered <command>, failed, changed;
# - ansible.builtin.copy's "Destination directory ... does not exist"
#   failure: the copy ACTION plugin seeds diff: [] and injects its
#   local_checksum into the module's failure, so the registered shape
#   leads with diff, then failed, msg, checksum, changed, exception.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Runs a play whose final task dumps a registered result as JSON into a
# file, and returns the dumped object's key order (insertion order
# survives JSON.parse). Extra process env (e.g. a PATH holding a fake
# virsh shim) is forwarded to the playbook run.
private def run_registered_dump(yaml : String, register : String = "r", check_mode : Bool = false,
                                env : Hash(String, String)? = nil) : Array(String)
  dump = PluginSpecHelper.tmp_path("kop-misc2-dump.json")
  playbook = File.tempname("kop-misc2-key-order", ".yml")
  File.write(playbook, yaml.gsub("KRIKRI_DUMP_PATH", dump).gsub("KRIKRI_REGISTER", register))
  output = IO::Memory.new
  args = ["-i", INVENTORY, playbook]
  args << "--check" if check_mode
  status = Process.run(BINARY, args, output: output, error: output, env: env)
  status.success?.must_equal(true, output.to_s[-800..]? || output.to_s)
  JSON.parse(File.read(dump)).as_h.keys
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

# Same play run, returning the full dumped object (for value pins).
private def run_registered_value(yaml : String, register : String = "r", check_mode : Bool = false,
                                 env : Hash(String, String)? = nil) : JSON::Any
  dump = PluginSpecHelper.tmp_path("kop-misc2-value.json")
  playbook = File.tempname("kop-misc2-key-value", ".yml")
  File.write(playbook, yaml.gsub("KRIKRI_DUMP_PATH", dump).gsub("KRIKRI_REGISTER", register))
  output = IO::Memory.new
  args = ["-i", INVENTORY, playbook]
  args << "--check" if check_mode
  status = Process.run(BINARY, args, output: output, error: output, env: env)
  status.success?.must_equal(true, output.to_s[-800..]? || output.to_s)
  JSON.parse(File.read(dump))
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private def registered_dump_play(tasks : String) : String
  # The task bodies arrive indented by an arbitrary common amount (they
  # are heredocs inside nested describe/it blocks); YAML cares only
  # about the RELATIVE shape, so re-anchor the common indent to the 4
  # spaces a `tasks:` list item needs (same approach as
  # key_order_sweep9_test.cr).
  lines = tasks.lines.reject(&.strip.empty?)
  common = lines.min_of { |line| line.size - line.lstrip.size }
  body = lines.map { |line| "    " + line.byte_slice(common, line.bytesize) + "\n" }.join
  "- hosts: localhost\n" \
  "  gather_facts: false\n" \
  "  connection: local\n" \
  "  tasks:\n" +
    body +
    "    - name: dump\n" \
    "      ansible.builtin.copy:\n" \
    "        dest: KRIKRI_DUMP_PATH\n" \
    "        content: |-\n" \
    "          {{ KRIKRI_REGISTER | to_json }}\n" \
    "      check_mode: false\n"
end

describe "round 994002 kop_misc2 registered key order" do
  describe "community.docker.current_container_facts" do
    # Whether THIS environment is a container, derived the same way the
    # module derives it (/proc/self/cpuset's cgroup path, then the
    # /etc/hostname mountinfo fallback) - the module answers honestly
    # wherever it runs, so a CI job container (cpuset .../actions_job/<id>)
    # reports running_in_container=true and the round's bare-host pins
    # only apply where there is no container.
    private def spec_in_container? : Bool
      cpuset = File.read("/proc/self/cpuset").strip rescue ""
      cgroup_path = cpuset.rpartition("/")[0]
      return true if ["/docker", "/azpl_job", "/actions_job"].includes?(cgroup_path) && cgroup_path != ""

      mountinfo = File.read("/proc/self/mountinfo") rescue ""
      mountinfo.each_line.any? do |line|
        parts = line.split
        parts.size >= 5 && parts[4] == "/etc/hostname" &&
          (/.*\/([a-f0-9]{64})\/hostname$/.matches?(parts[3]) ||
            /.*\/([a-f0-9]{64})\/userdata\/hostname$/.matches?(parts[3]))
      end
    end

    it "registers ansible_facts, failed, changed" do
      value = run_registered_value(registered_dump_play(<<-YAML))
        - name: gather container facts
          community.docker.current_container_facts:
          register: KRIKRI_REGISTER
      YAML
      value.as_h.keys.must_equal(["changed", "failed", "ansible_facts"])
      if spec_in_container?
        value["ansible_facts"]["ansible_module_running_in_container"].as_bool.must_equal(true)
        value["ansible_facts"]["ansible_module_container_id"].as_s.wont_be_empty
        ["docker", "podman", "azure_pipelines", "github_actions"].must_include(
          value["ansible_facts"]["ansible_module_container_type"].as_s)
      else
        value["ansible_facts"]["ansible_module_running_in_container"].as_bool.must_equal(false)
        value["ansible_facts"]["ansible_module_container_id"].as_s.must_equal("")
        value["ansible_facts"]["ansible_module_container_type"].as_s.must_equal("")
      end
      value["changed"].as_bool.must_equal(false)
    end
  end

  describe "community.libvirt.virt_net command: undefine" do
    # The undefine-on-missing-network shape needs `virsh` present (the
    # HAS_VIRT gate); a shim that always fails its probes stands in for
    # a libvirt daemon with no networks - the Ansible module's
    # EntryNotFound path. The registered shape leads a `deprecations`
    # key: virt_net.py:142 imports to_native from the deprecated
    # ansible.module_utils._text path at module level, so ansible-core
    # 2.21's shim deprecates it before the body runs and 2.21's
    # registered export puts that collected entry in its leading field
    # block, ahead of every module key (the round's 2.19.11 capture
    # predates that shim - the same re-capture issue #992 made for
    # sysctl; re-verified against ansible-core 2.21.6 real).
    it "registers undefine, failed, changed with no changed on the wire" do
      shim_dir = PluginSpecHelper.tmp_path("kop-virsh-shim")
      Dir.mkdir_p(shim_dir)
      shim = File.join(shim_dir, "virsh")
      # A virsh whose every probe fails: net-info/net-dumpxml exit
      # nonzero, which is exactly Ansible's EntryNotFound path for a
      # libvirt daemon with no networks.
      File.write(shim, "#!/bin/sh\nexit 1\n")
      File.chmod(shim, 0o755)
      env = {"PATH" => "#{shim_dir}:#{ENV["PATH"]}"}

      value = run_registered_value(registered_dump_play(<<-YAML), env: env)
        - name: undefine a network that does not exist
          community.libvirt.virt_net:
            name: kop_probe_net
            command: undefine
          register: KRIKRI_REGISTER
      YAML
      value.as_h.keys.must_equal(["changed", "failed", "deprecations", "undefine"])
      value["undefine"].as_nil.must_be_nil
      value["failed"].as_bool.must_equal(false)
      value["changed"].as_bool.must_equal(false)
    end
  end

  describe "community.libvirt.virt_net failure msgs match real (round 995005)" do
    # Real talks to libvirt through its python bindings and reports
    # libvirt's own error text ("network %s not found" for a missing
    # network, the raw libvirt XML error for a bad define). Krikri shells
    # out to virsh, whose stderr wraps the same errors as "error: " lines
    # with an extra "Failed to ..." headline - the shim reproduces those
    # wrappers so the mapped plugin msgs can be pinned to Ansible's.
    it "maps a missing network on start to Ansible's 'network NAME not found'" do
      value = run_registered_value(registered_dump_play(<<-YAML), env: missing_net_shim_env)
        - name: start a network that does not exist
          community.libvirt.virt_net:
            name: kop_probe_net
            state: active
          register: KRIKRI_REGISTER
          ignore_errors: true
      YAML
      value["failed"].as_bool.must_equal(true)
      value["msg"].as_s.must_equal("network kop_probe_net not found")
    end

    it "maps a missing network on get_xml to Ansible's 'network NAME not found'" do
      value = run_registered_value(registered_dump_play(<<-YAML), env: missing_net_shim_env)
        - name: get xml of a network that does not exist
          community.libvirt.virt_net:
            name: kop_probe_net
            command: get_xml
          register: KRIKRI_REGISTER
          ignore_errors: true
      YAML
      value["failed"].as_bool.must_equal(true)
      value["msg"].as_s.must_equal("network kop_probe_net not found")
    end

    it "maps a missing network on status to Ansible's 'network NAME not found'" do
      value = run_registered_value(registered_dump_play(<<-YAML), env: missing_net_shim_env)
        - name: status of a network that does not exist
          community.libvirt.virt_net:
            name: kop_probe_net
            command: status
          register: KRIKRI_REGISTER
          ignore_errors: true
      YAML
      value["failed"].as_bool.must_equal(true)
      value["msg"].as_s.must_equal("network kop_probe_net not found")
    end

    it "passes the libvirt XML error through verbatim on a define failure" do
      value = run_registered_value(registered_dump_play(<<-YAML), env: missing_net_shim_env)
        - name: define a network with bad xml
          community.libvirt.virt_net:
            name: kop_probe_net
            command: define
            xml: |
              <network>
                <name>kop_probe_net</name>
                <ip address="10.99.99.1" netmask="255.255.255.0">
                  <dhcp range start="10.99.99.10" end="10.99.99.20"/>
                </ip>
              </network>
          register: KRIKRI_REGISTER
          ignore_errors: true
      YAML
      value["failed"].as_bool.must_equal(true)
      # str(libvirtError) verbatim: virsh's "error: " prefixes and its
      # "Failed to define network from <tmpfile>" headline are stripped.
      value["msg"].as_s.must_equal(<<-MSG)
      (network_definition):5: Specification mandates value for attribute range
          <dhcp range start="10.99.99.10" end="10.99.99.20"/>
      ----------------^
      MSG
    end

    private def missing_net_shim_env
      shim_dir = PluginSpecHelper.tmp_path("kop-virsh-shim-missing")
      Dir.mkdir_p(shim_dir)
      shim = File.join(shim_dir, "virsh")
      File.write(shim, <<-SH)
      #!/bin/sh
      case "$3" in
        net-info|net-dumpxml|net-start)
          echo "error: failed to get network '$4'" >&2
          echo "error: Network not found: no network with matching name '$4'" >&2
          exit 1 ;;
        net-define)
          echo "error: Failed to define network from $4" >&2
          echo "error: (network_definition):5: Specification mandates value for attribute range" >&2
          echo '    <dhcp range start="10.99.99.10" end="10.99.99.20"/>' >&2
          echo "----------------^" >&2
          exit 1 ;;
        *) exit 1 ;;
      esac
      SH
      File.chmod(shim, 0o755)
      {"PATH" => "#{shim_dir}:#{ENV["PATH"]}"}
    end
  end

  describe "community.libvirt.virt_net state: msg carries Ansible's libvirt rc (round 996005)" do
    # Ansible's core() puts the libvirt return value itself into `msg` on
    # every state branch that changed anything:
    # `res['msg'] = v.start(name)` / `v.destroy(name)` /
    # v.undefine(name), each of which returns what libvirt's
    # network.create()/destroy()/undefine() returned - the error code 0,
    # as a NATIVE int. The round996005 cold_py.out capture registered
    # exactly {changed: true, msg: 0, failed: false} for both
    # virt_net_start (state: active) and virt_net_stop (state: inactive);
    # krikri registered [changed, failed] with no msg at all. The
    # check-mode branch keeps NO msg (Ansible's conn.create/destroy exit
    # from inside the method there, round994002 virt_net_check), and an
    # already-converged state keeps no msg either. Every shape trails a
    # `deprecations` key: virt_net.py:142 imports to_native from the
    # deprecated ansible.module_utils._text path at module level, so
    # ansible-core 2.21's shim deprecates it before the body runs and the
    # controller appends the entry after every module key (the round's
    # 2.19.11 captures predate that shim - the same re-capture issue #992
    # made for sysctl; re-verified against ansible-core 2.21.6 real).
    private def stateful_virsh_shim_env
      shim_dir = PluginSpecHelper.tmp_path("kop-virsh-shim-state")
      Dir.mkdir_p(shim_dir)
      defined_path = File.join(shim_dir, "net-defined")
      active_path = File.join(shim_dir, "net-active")
      File.write(defined_path, "kop_probe_net\n")
      File.write(File.join(shim_dir, "virsh"), <<-SH)
      #!/bin/sh
      # "virsh --connect <uri> <subcommand> <name> ..." against a
      # libvirt daemon holding exactly one defined network.
      case "$3" in
        net-info)
          [ -f "$KRIKRI_VIRSH_DEFINED" ] || exit 1
          if [ -f "$KRIKRI_VIRSH_ACTIVE" ]; then a=yes; else a=no; fi
          printf 'Name:           kop_probe_net\\n'
          printf 'UUID:           8abce183-25f4-42f4-883f-473f8509aa41\\n'
          printf 'Active:         %s\\n' "$a"
          printf 'Autostart:      no\\n'
          printf 'Persistent:     yes\\n'
          printf 'Bridge:         kopbr0\\n'
          exit 0 ;;
        net-dumpxml)
          [ -f "$KRIKRI_VIRSH_DEFINED" ] || exit 1
          printf '<network>\\n  <name>kop_probe_net</name>\\n</network>\\n'
          exit 0 ;;
        net-list)
          [ -f "$KRIKRI_VIRSH_DEFINED" ] && echo kop_probe_net
          exit 0 ;;
        net-start)
          [ -f "$KRIKRI_VIRSH_DEFINED" ] || exit 1
          touch "$KRIKRI_VIRSH_ACTIVE"
          exit 0 ;;
        net-destroy)
          rm -f "$KRIKRI_VIRSH_ACTIVE"
          exit 0 ;;
        net-undefine)
          rm -f "$KRIKRI_VIRSH_DEFINED"
          exit 0 ;;
      esac
      exit 1
      SH
      File.chmod(File.join(shim_dir, "virsh"), 0o755)
      env = {
        "PATH"                 => "#{shim_dir}:#{ENV["PATH"]}",
        "KRIKRI_VIRSH_DEFINED" => defined_path,
        "KRIKRI_VIRSH_ACTIVE"  => active_path,
      }
      {env: env, active: active_path}
    end

    it "registers state=active as changed, msg 0, failed" do
      shim = stateful_virsh_shim_env
      value = run_registered_value(registered_dump_play(<<-YAML), env: shim[:env])
        - name: start the probe network (changed)
          community.libvirt.virt_net:
            name: kop_probe_net
            state: active
          register: KRIKRI_REGISTER
      YAML
      value.as_h.keys.must_equal(["changed", "failed", "deprecations", "msg"])
      value["changed"].as_bool.must_equal(true)
      value["msg"].raw.must_equal(0_i64)
      value["failed"].as_bool.must_equal(false)
    end

    it "registers an already-active rerun as changed, failed with no msg" do
      shim = stateful_virsh_shim_env
      value = run_registered_value(registered_dump_play(<<-YAML), env: shim[:env])
        - name: start the probe network (changed)
          community.libvirt.virt_net:
            name: kop_probe_net
            state: active
          register: setup
        - name: start it again (no-op)
          community.libvirt.virt_net:
            name: kop_probe_net
            state: active
          register: KRIKRI_REGISTER
      YAML
      value.as_h.keys.must_equal(["changed", "failed", "deprecations"])
      value["changed"].as_bool.must_equal(false)
      value.as_h.has_key?("msg").must_equal(false)
    end

    it "registers state=inactive with msg 0 too" do
      shim = stateful_virsh_shim_env
      File.write(shim[:active], "")
      value = run_registered_value(registered_dump_play(<<-YAML), env: shim[:env])
        - name: stop the probe network (changed)
          community.libvirt.virt_net:
            name: kop_probe_net
            state: inactive
          register: KRIKRI_REGISTER
      YAML
      value.as_h.keys.must_equal(["changed", "failed", "deprecations", "msg"])
      value["changed"].as_bool.must_equal(true)
      value["msg"].raw.must_equal(0_i64)
    end

    it "registers state=absent with msg 0 (Ansible's undefine return)" do
      shim = stateful_virsh_shim_env
      value = run_registered_value(registered_dump_play(<<-YAML), env: shim[:env])
        - name: undefine the probe network (changed)
          community.libvirt.virt_net:
            name: kop_probe_net
            state: absent
          register: KRIKRI_REGISTER
      YAML
      value.as_h.keys.must_equal(["changed", "failed", "deprecations", "msg"])
      value["changed"].as_bool.must_equal(true)
      value["msg"].raw.must_equal(0_i64)
    end

    it "keeps the check-mode state change msg-less (Ansible exits from inside the method)" do
      shim = stateful_virsh_shim_env
      value = run_registered_value(registered_dump_play(<<-YAML), env: shim[:env], check_mode: true)
        - name: start the probe network in check mode (changed)
          community.libvirt.virt_net:
            name: kop_probe_net
            state: active
          register: KRIKRI_REGISTER
      YAML
      value.as_h.keys.must_equal(["changed", "failed", "deprecations"])
      value["changed"].as_bool.must_equal(true)
    end
  end

  describe "ansible.builtin.copy missing destination directory failure" do
    it "leads with diff, then failed, msg, checksum, changed, exception" do
      missing_parent = File.join(PluginSpecHelper.tmp_path("kop-missing-dest"), "sub")
      dest = File.join(missing_parent, "file.txt")
      content = "unfinished\n"
      value = run_registered_value(registered_dump_play(<<-YAML))
        - name: copy into a missing directory
          ansible.builtin.copy:
            content: "#{content.strip}\\n"
            dest: #{dest}
          register: KRIKRI_REGISTER
          ignore_errors: true
      YAML
      value.as_h.keys.must_equal(["changed", "failed", "exception", "msg", "diff", "checksum"])
      value["diff"].as_a.size.must_equal(0)
      value["msg"].as_s.must_equal("Destination directory #{missing_parent} does not exist")
      value["checksum"].as_s.must_equal(Digest::SHA1.hexdigest("#{content.strip}\n"))
      value["changed"].as_bool.must_equal(false)
    end
  end
end
