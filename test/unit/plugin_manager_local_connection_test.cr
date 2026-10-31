require "../minitest_helper"
require "../../src/krikri/plugin_manager"
require "../../src/krikri/host"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

# Issue #684: a play-level `connection: local` was parsed nowhere, so the
# whole play still went over SSH - the eager plugin upload (and every task)
# dialed the host and UNREACHABLEd, where real ansible-playbook runs the
# play on the controller. These run the full binary against an inventory
# host whose ssh connection is refused instantly (127.0.0.1 port 1), so
# "did it go remote" shows up in the recap without any dial-out wait.
private def run_playbook_issue684(playbook_body : String, inventory_line : String = "farhost ansible_host=127.0.0.1 ansible_port=1 ansible_user=root") : String
  root = PluginSpecHelper.tmp_path("plugin_manager_local_connection_issue684")
  FileUtils.rm_rf(root) if Dir.exists?(root)
  Dir.mkdir_p(root)
  inventory = File.join(root, "inventory.ini")
  File.write(inventory, "#{inventory_line}\n")
  playbook = File.join(root, "site.yml")
  File.write(playbook, playbook_body)
  out_io = IO::Memory.new
  err_io = IO::Memory.new
  Process.run(BINARY, ["-i", inventory, playbook], output: out_io, error: err_io)
  out_io.to_s
ensure
  FileUtils.rm_rf(root) if root && Dir.exists?(root)
end

private def issue684_recap(output : String) : String
  output.lines.reverse!.find!(&.includes?("ok="))
end

# Issue #677: the host NAME is never a local-connection vote. Real
# ansible-core (2.19.11, live-verified) runs an inventory-defined
# "localhost"/"127.0.0.1" over plain ssh - `{{ ansible_connection }}`
# renders "ssh" on a bare inventory localhost entry, and one carrying
# connection vars (ansible_port=2299) SSHes to that port. Only the
# IMPLICIT localhost (auto-created when no inventory entry exists) is
# local, and it is local because ansible SETS ansible_connection=local
# on it - this engine mirrors that at both implicit-creation sites
# (InventoryParser's pattern resolver and the unresolvable-delegate
# fallback), so "local localhost" always arrives here through the var.
describe "Krikri::PluginManager (plugin_manager_local_connection_test.cr)" do
  describe ".local_connection?" do
    it "treats an implicit localhost (ansible_connection=local var) as local" do
      # What InventoryParser#single_pattern_hosts and the unresolvable-
      # delegate fallback actually build - `delegate_to: localhost` /
      # `delegate_to: 127.0.0.1` with no inventory entry resolves to one
      # of these (ansible-community.ansible-vault's delegate_to:
      # 127.0.0.1 unarchive idiom).
      implicit = Krikri::Host.new("localhost", "root", 22)
      implicit.vars["ansible_connection"] = JSON::Any.new("local")
      Krikri::PluginManager.local_connection?(implicit, implicit.vars).must_equal(true)

      loopback = Krikri::Host.new("127.0.0.1", "root", 22)
      loopback.vars["ansible_connection"] = JSON::Any.new("local")
      Krikri::PluginManager.local_connection?(loopback, loopback.vars).must_equal(true)
    end

    it "does not treat an inventory-defined bare localhost as local (real: ssh)" do
      # Live-verified vs ansible-playbook 2.19.11: a bare inventory
      # `localhost` line UNREACHABLEs with "ssh: connect to host
      # localhost port 22: Connection refused" - the name alone is not
      # the implicit localhost.
      host = Krikri::Host.new("localhost")
      Krikri::PluginManager.local_connection?(host, host.vars).must_equal(false)
    end

    it "does not treat an inventory localhost with connection vars as local (issue #677)" do
      host = Krikri::Host.new("localhost", "tester", 2299)
      host.vars["ansible_port"] = JSON::Any.new(2299)
      host.vars["ansible_user"] = JSON::Any.new("tester")
      Krikri::PluginManager.local_connection?(host, host.vars).must_equal(false)
    end

    it "does not treat a bare 127.0.0.1 inventory host as local" do
      host = Krikri::Host.new("127.0.0.1")
      Krikri::PluginManager.local_connection?(host, host.vars).must_equal(false)
    end

    it "does not treat an ordinary remote host as local" do
      host = Krikri::Host.new("web1.example.com")
      Krikri::PluginManager.local_connection?(host, host.vars).must_equal(false)
    end

    it "still honors ansible_connection: local for any host name" do
      host = Krikri::Host.new("web1.example.com")
      host.vars["ansible_connection"] = JSON::Any.new("local")
      Krikri::PluginManager.local_connection?(host, host.vars).must_equal(true)
    end

    it "the passed vars decide only when the host's own vars are silent" do
      # Same-host (non-delegate) case: vars is the host's own merged
      # context, so a task-level `connection: local` override lands here.
      host = Krikri::Host.new("web1.example.com")
      vars = {"ansible_connection" => JSON::Any.new("local")}
      Krikri::PluginManager.local_connection?(host, vars).must_equal(true)
    end
  end

  describe "play-level connection: local end to end (issue #684)" do
    it "runs a command task locally on an ssh-refusing inventory host" do
      recap = issue684_recap(run_playbook_issue684(<<-YAML))
        - hosts: all
          connection: local
          gather_facts: false
          tasks:
            - ansible.builtin.command: hostname
              changed_when: false
        YAML

      recap.must_include("ok=1")
      recap.must_include("unreachable=0")
      recap.must_include("failed=0")
    end

    it "still gathers facts locally under the play keyword on the same host" do
      recap = issue684_recap(run_playbook_issue684(<<-YAML))
        - hosts: all
          connection: local
          tasks:
            - ansible.builtin.command: hostname
              changed_when: false
        YAML

      recap.must_include("ok=2")
      recap.must_include("unreachable=0")
      recap.must_include("failed=0")
    end

    it "keeps a task-level connection: ssh remote against the play keyword" do
      # The task's own connection: keyword is that task's explicit choice
      # and stays unconditional (live-verified shape vs 2.19: the task
      # goes remote and UNREACHABLEs on the refused port).
      recap = issue684_recap(run_playbook_issue684(<<-YAML))
        - hosts: all
          connection: local
          gather_facts: false
          tasks:
            - ansible.builtin.command: hostname
              connection: ssh
              changed_when: false
        YAML

      recap.must_include("ok=0")
      recap.must_include("unreachable=1")
      recap.must_include("failed=0")
    end

    it "lets a play vars ansible_connection outrank the play keyword" do
      # Live-verified vs ansible-playbook 2.19: the play keyword ranks
      # BELOW play vars too.
      recap = issue684_recap(run_playbook_issue684(<<-YAML))
        - hosts: all
          connection: local
          gather_facts: false
          vars:
            ansible_connection: ssh
          tasks:
            - ansible.builtin.command: hostname
              changed_when: false
        YAML

      recap.must_include("ok=0")
      recap.must_include("unreachable=1")
      recap.must_include("failed=0")
    end

    it "keeps an inventory ansible_connection var above the play keyword" do
      # Ansible's vars-vs-keyword rule: an explicit inventory
      # ansible_connection wins over the play keyword (live-verified vs
      # 2.19: the entry keeps ssh'ing under a play `connection: local`).
      recap = issue684_recap(run_playbook_issue684(<<-YAML, "farhost ansible_host=127.0.0.1 ansible_port=1 ansible_user=root ansible_connection=ssh"))
        - hosts: all
          connection: local
          gather_facts: false
          tasks:
            - ansible.builtin.command: hostname
              changed_when: false
        YAML

      recap.must_include("ok=0")
      recap.must_include("unreachable=1")
      recap.must_include("failed=0")
    end
  end
end
