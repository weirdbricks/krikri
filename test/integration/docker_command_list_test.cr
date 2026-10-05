require "../minitest_helper"

# community.docker.docker_container's list-valued options, live-verified
# against ansible-core 2.19.11 + community.docker 5.2.1 driving a
# Docker-API socket (podman `system service`):
#
# - `command:` is an ansible-type `raw` option. A YAML LIST reaches the
#   daemon as the argv list verbatim (an element containing a space or a
#   comma stays ONE element); a STRING is POSIX-shell-split by Ansible's own
#   `_preprocess_command` (`shlex.split`) under its default
#   `command_handling: correct`.
# - `entrypoint:` is a plain `type: list, elements: str`. A LIST is used
#   as-is; a STRING is turned into a list by Ansible's own
#   comma-separated conversion - deliberately NOT shell-split, which is
#   why Ansible's `entrypoint: /bin/sh -c` stays a single argv element
#   (verified live: the daemon then looks for a file literally named
#   "/bin/sh -c" and the start fails).
# - `volumes:` is list-typed too: a list verbatim, a string comma-split.
#
# Every spec drives a whole play through the compiled binary, so the
# parser's own YAML-list wire is exercised too, and reads the resulting
# Config.Cmd/Config.Entrypoint straight off the daemon's inspect output -
# the exact field real compares against. The socket is
# `/tmp/krikri-kp-dk2.sock`; every spec skips when it is not up, and
# every container here is named krikri-kp-dk2-cl-*.
DOCKER_CMD_LIST_SOCKET      = "unix:///tmp/krikri-kp-dk2.sock"
DOCKER_CMD_LIST_SOCKET_PATH = "/tmp/krikri-kp-dk2.sock"
DOCKER_CMD_LIST_BINARY      = File.expand_path("../../bin/krikri-playbook", __DIR__)
DOCKER_CMD_LIST_IMAGE       = "docker.io/library/alpine:latest"

def docker_cmd_list_socket? : Bool
  File.exists?(DOCKER_CMD_LIST_SOCKET_PATH)
end

def docker_cmd_list_remove(name : String) : Nil
  Process.run("podman", ["rm", "-f", name], output: Process::Redirect::Close, error: Process::Redirect::Close)
end

def docker_cmd_list_play(yaml : String) : String
  playbook = PluginSpecHelper.tmp_path("dk2-cmd-list.yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  Process.run(DOCKER_CMD_LIST_BINARY, ["-i", "localhost,", "-c", "local", playbook],
    output: output, error: output)
  output.to_s
end

def docker_cmd_list_json(name : String, field : String) : String
  buf = IO::Memory.new
  Process.run("podman", ["inspect", name, "--format", "{{json .Config.#{field}}}"],
    output: buf, error: buf)
  buf.to_s.strip
end

describe "docker_container list-valued command params" do
  serial!

  it "passes a YAML list command to the daemon as an argv list" do
    skip("no Docker-API socket at #{DOCKER_CMD_LIST_SOCKET_PATH}") unless docker_cmd_list_socket?
    name = "krikri-kp-dk2-cl-list"
    docker_cmd_list_remove(name)
    begin
      output = docker_cmd_list_play(<<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - community.docker.docker_container:
              name: #{name}
              image: #{DOCKER_CMD_LIST_IMAGE}
              command: [sleep, "30"]
              state: present
              docker_host: #{DOCKER_CMD_LIST_SOCKET}
      YAML
      output.includes?("failed=0").must_equal(true)
      # Ansible's own Config.Cmd for `command: [sleep, "30"]`
      docker_cmd_list_json(name, "Cmd").must_equal(%(["sleep","30"]))
    ensure
      docker_cmd_list_remove(name)
    end
  end

  it "keeps an element containing spaces as one argv element" do
    skip("no Docker-API socket at #{DOCKER_CMD_LIST_SOCKET_PATH}") unless docker_cmd_list_socket?
    name = "krikri-kp-dk2-cl-spaces"
    docker_cmd_list_remove(name)
    begin
      docker_cmd_list_play(<<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - community.docker.docker_container:
              name: #{name}
              image: #{DOCKER_CMD_LIST_IMAGE}
              command: [sh, -c, "echo hello world"]
              state: present
              docker_host: #{DOCKER_CMD_LIST_SOCKET}
      YAML
      docker_cmd_list_json(name, "Cmd").must_equal(%(["sh","-c","echo hello world"]))
    ensure
      docker_cmd_list_remove(name)
    end
  end

  it "shell-splits a string command exactly like Ansible's shlex.split" do
    skip("no Docker-API socket at #{DOCKER_CMD_LIST_SOCKET_PATH}") unless docker_cmd_list_socket?
    name = "krikri-kp-dk2-cl-str"
    docker_cmd_list_remove(name)
    begin
      docker_cmd_list_play(<<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - community.docker.docker_container:
              name: #{name}
              image: #{DOCKER_CMD_LIST_IMAGE}
              command: "sh -c 'echo hi there'"
              state: present
              docker_host: #{DOCKER_CMD_LIST_SOCKET}
      YAML
      docker_cmd_list_json(name, "Cmd").must_equal(%(["sh","-c","echo hi there"]))
    ensure
      docker_cmd_list_remove(name)
    end
  end

  it "passes a list entrypoint through unchanged" do
    skip("no Docker-API socket at #{DOCKER_CMD_LIST_SOCKET_PATH}") unless docker_cmd_list_socket?
    name = "krikri-kp-dk2-cl-ep-list"
    docker_cmd_list_remove(name)
    begin
      docker_cmd_list_play(<<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - community.docker.docker_container:
              name: #{name}
              image: #{DOCKER_CMD_LIST_IMAGE}
              entrypoint: ["/bin/sh", "-c"]
              command: "echo entry"
              state: present
              docker_host: #{DOCKER_CMD_LIST_SOCKET}
      YAML
      docker_cmd_list_json(name, "Entrypoint").must_equal(%(["/bin/sh","-c"]))
      docker_cmd_list_json(name, "Cmd").must_equal(%(["echo","entry"]))
    ensure
      docker_cmd_list_remove(name)
    end
  end

  it "keeps a string entrypoint as one argv element like Ansible's list conversion" do
    skip("no Docker-API socket at #{DOCKER_CMD_LIST_SOCKET_PATH}") unless docker_cmd_list_socket?
    name = "krikri-kp-dk2-cl-ep-str"
    docker_cmd_list_remove(name)
    begin
      docker_cmd_list_play(<<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - community.docker.docker_container:
              name: #{name}
              image: #{DOCKER_CMD_LIST_IMAGE}
              entrypoint: "/bin/sh -c"
              command: "echo entry"
              state: present
              docker_host: #{DOCKER_CMD_LIST_SOCKET}
      YAML
      # Real ends up with Config.Entrypoint == ["/bin/sh -c"] - ONE
      # element - which the daemon then fails to exec; identical here.
      docker_cmd_list_json(name, "Entrypoint").must_equal(%(["/bin/sh -c"]))
    ensure
      docker_cmd_list_remove(name)
    end
  end

  it "creates the same binds from a list volumes as from the string form" do
    skip("no Docker-API socket at #{DOCKER_CMD_LIST_SOCKET_PATH}") unless docker_cmd_list_socket?
    list_name = "krikri-kp-dk2-cl-vol-list"
    string_name = "krikri-kp-dk2-cl-vol-str"
    docker_cmd_list_remove(list_name)
    docker_cmd_list_remove(string_name)
    begin
      docker_cmd_list_play(<<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - community.docker.docker_container:
              name: #{list_name}
              image: #{DOCKER_CMD_LIST_IMAGE}
              command: [sleep, "30"]
              volumes:
                - /tmp/krikri-kp-dk2-vol:/data:ro
              state: present
              docker_host: #{DOCKER_CMD_LIST_SOCKET}
          - community.docker.docker_container:
              name: #{string_name}
              image: #{DOCKER_CMD_LIST_IMAGE}
              command: [sleep, "30"]
              volumes: "/tmp/krikri-kp-dk2-vol:/data:ro"
              state: present
              docker_host: #{DOCKER_CMD_LIST_SOCKET}
      YAML
      binds_of = ->(name : String) {
        buf = IO::Memory.new
        Process.run("podman", ["inspect", name, "--format", "{{json .HostConfig.Binds}}"],
          output: buf, error: buf)
        buf.to_s.strip
      }
      binds_of.call(list_name).must_include("/tmp/krikri-kp-dk2-vol:/data:ro")
      binds_of.call(string_name).must_equal(binds_of.call(list_name))
    ensure
      docker_cmd_list_remove(list_name)
      docker_cmd_list_remove(string_name)
    end
  end

  it "is idempotent when a list command reruns unchanged" do
    skip("no Docker-API socket at #{DOCKER_CMD_LIST_SOCKET_PATH}") unless docker_cmd_list_socket?
    name = "krikri-kp-dk2-cl-idem"
    docker_cmd_list_remove(name)
    begin
      output = docker_cmd_list_play(<<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - community.docker.docker_container:
              name: #{name}
              image: #{DOCKER_CMD_LIST_IMAGE}
              command: [sh, -c, "echo hello world"]
              state: present
              docker_host: #{DOCKER_CMD_LIST_SOCKET}
            register: first
          - community.docker.docker_container:
              name: #{name}
              image: #{DOCKER_CMD_LIST_IMAGE}
              command: [sh, -c, "echo hello world"]
              state: present
              docker_host: #{DOCKER_CMD_LIST_SOCKET}
            register: second
          - debug:
              msg: "{{ [first.changed, second.changed] | to_json }}"
          - community.docker.docker_container:
              name: #{name}
              state: absent
              docker_host: #{DOCKER_CMD_LIST_SOCKET}
      YAML
      # real: first run changed, identical rerun unchanged - krikri
      # matches (the same pattern as its existing string-command specs).
      output.scan(/\[true, false\]/).wont_be_empty
    ensure
      docker_cmd_list_remove(name)
    end
  end

  it "records the argv list in a check_mode create action" do
    skip("no Docker-API socket at #{DOCKER_CMD_LIST_SOCKET_PATH}") unless docker_cmd_list_socket?
    result = PluginSpecHelper.run_raw("docker_container",
      {"name" => JSON::Any.new("krikri-kp-dk2-cl-cm"), "image" => JSON::Any.new(DOCKER_CMD_LIST_IMAGE),
       "command" => JSON::Any.new("[\"sh\", \"-c\", \"echo hello world\"]"),
       "state" => JSON::Any.new("present"), "docker_host" => JSON::Any.new(DOCKER_CMD_LIST_SOCKET),
       "_ansible_check_mode" => JSON::Any.new(true)})
    result["actions"].as_a[0]["create_parameters"]["Cmd"].as_a.map(&.as_s)
      .must_equal(["sh", "-c", "echo hello world"])
  end
end
