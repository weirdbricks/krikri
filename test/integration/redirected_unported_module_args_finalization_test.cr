require "../minitest_helper"

# An unported module whose bare name carries an ansible_builtin_runtime.yml
# redirect still shows the redirected FQCN in the task-args finalization
# error: ansible's loader routes a bare name through the builtin runtime's
# redirect table before any collection lookup, so the finalization failure
# for bare `docker_swarm_service:` (no krikri plugin, undefined var in the
# args) names 'community.docker.docker_swarm_service', not the bare name
# as written. Live-captured against ansible-core 2.19.11.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("redirected-module-args", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "redirected unported module args finalization" do
  it "names the redirected FQCN in the finalization error" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: undef args on redirected unported module
            docker_swarm_service:
              name: "{{ docker_swarm_service_name }}"
              image: foo
          - name: sentinel
            ansible.builtin.debug:
              msg: SHOULD-RUN-AFTER
      YAML

    status.exit_code.must_equal(2)
    output.must_include("Finalization of task args for 'community.docker.docker_swarm_service' failed: Error while resolving value for 'name': 'docker_swarm_service_name' is undefined")
    output.must_include("failed=1")
    # A failed task halts the host, so the sentinel task never runs -
    # matches real ansible.
    output.wont_include("SHOULD-RUN-AFTER")
  end
end
