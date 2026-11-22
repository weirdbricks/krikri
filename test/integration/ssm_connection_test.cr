require "../minitest_helper"
require "krikri-aws-ssm/testing"
require "../../src/krikri/ssm_settings"
require "../../src/krikri/ssm_unreachable_msg"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

# The credentials the fake gateway verifies every control-plane call and
# websocket upgrade against. The child process gets the same values through
# AWS_*, so both sides of SigV4 agree.
private SSM_ACCESS_KEY    = "AKIDEXAMPLE"
private SSM_SECRET_KEY    = "secretEXAMPLEKEY"
private SSM_SESSION_TOKEN = "session-token"
private SSM_CREDS         = KrikriAwsSsm::Credentials.new(SSM_ACCESS_KEY, SSM_SECRET_KEY, SSM_SESSION_TOKEN)

# The child's environment: static credentials (so the shard's chain is
# never consulted), an explicit region, and no ambient profile/SSO/IMDS
# surprises. Every test starts from this and overrides as needed.
private def ssm_child_env : Hash(String, String)
  {
    "KRIKRI_PLAYBOOK_DEADLINE_SECONDS" => "240",
    "AWS_ACCESS_KEY_ID"                => SSM_ACCESS_KEY,
    "AWS_SECRET_ACCESS_KEY"            => SSM_SECRET_KEY,
    "AWS_SESSION_TOKEN"                => SSM_SESSION_TOKEN,
    "AWS_REGION"                       => "us-east-1",
    "AWS_DEFAULT_REGION"               => "us-east-1",
    "AWS_CONFIG_FILE"                  => "/dev/null",
    "AWS_SHARED_CREDENTIALS_FILE"      => "/dev/null",
    "AWS_EC2_METADATA_DISABLED"        => "true",
  }
end

private def with_ssm_gateway(options : KrikriAwsSsm::Testing::FakeAgent::Options? = nil, &)
  gateway = KrikriAwsSsm::Testing::FakeGateway.new(SSM_CREDS, options || KrikriAwsSsm::Testing::FakeAgent::Options.new)
  begin
    yield gateway
  ensure
    gateway.close
  end
end

private def write_ssm_files(gateway : KrikriAwsSsm::Testing::FakeGateway,
                            playbook_body : String,
                            inventory_vars : String,
                            connection : String = "aws_ssm") : {String, String}
  tag = Random::Secure.hex(4)
  playbook = PluginSpecHelper.tmp_path("ssm-#{tag}.yml")
  inventory = PluginSpecHelper.tmp_path("ssm-#{tag}.ini")
  File.write(playbook, playbook_body)
  File.write(inventory, <<-INI)
    [targets]
    ssm-target ansible_connection=#{connection} ansible_host=i-0123456789 ansible_aws_ssm_region=us-east-1 ansible_aws_ssm_endpoint_url=#{gateway.url} #{inventory_vars}
    INI
  {playbook, inventory}
end

private def delete_ssm_files(*paths : String) : Nil
  paths.each { |path| File.delete(path) if File.exists?(path) }
end

private def run_ssm_playbook(
  gateway : KrikriAwsSsm::Testing::FakeGateway,
  playbook_body : String,
  inventory_vars : String = "",
  cli_args : Array(String) = [] of String,
  env : Hash(String, String)? = nil,
  connection : String = "aws_ssm",
) : {Process::Status, String}
  playbook, inventory = write_ssm_files(gateway, playbook_body, inventory_vars, connection)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", inventory] + cli_args + [playbook],
    input: IO::Memory.new, output: output, error: output,
    env: env || ssm_child_env)
  {status, output.to_s}
ensure
  delete_ssm_files(playbook, inventory) if playbook && inventory
end

describe "aws_ssm connection" do
  # The fake agent's pty shell runs on this machine and stages plugin
  # binaries under the shared ssm-user /var/tmp tree, so these tests must
  # not overlap with each other.
  serial!

  it "runs a command through a native SSM session" do
    with_ssm_gateway do |gateway|
      status, output = run_ssm_playbook(gateway, <<-YAML)
        - hosts: ssm-target
          gather_facts: false
          tasks:
            - name: run a command over SSM
              command: echo SSM-OK
              register: out
            - name: show the command output
              debug: {msg: "{{ out.stdout }}"}
        YAML

      assert status.success?, output
      assert_includes output, "SSM-OK"
      assert_includes output, "ok=2"
      # FakeGateway rejects an upgrade whose Host/signature does not verify,
      # so reaching this point already proves SigV4; pin the signed set too.
      result = gateway.next_upgrade_result(30.seconds)
      raise "no websocket upgrade was recorded" unless result
      assert_equal ["host", "x-amz-date", "x-amz-security-token"], result.signed_headers
    end
  end

  it "accepts the amazon.aws.aws_ssm spelling and the legacy one" do
    with_ssm_gateway do |gateway|
      %w[amazon.aws.aws_ssm community.aws.aws_ssm].each do |spelling|
        status, output = run_ssm_playbook(gateway, <<-YAML, connection: spelling)
          - hosts: ssm-target
            gather_facts: false
            tasks:
              - command: echo #{spelling}
                register: out
              - debug: {msg: "{{ out.stdout }}"}
          YAML
        assert status.success?, "#{spelling}: #{output}"
        assert_includes output, spelling
      end
    end
  end

  it "uploads and fetches a file over the session" do
    with_ssm_gateway do |gateway|
      remote = PluginSpecHelper.tmp_path("ssm-remote-#{Random::Secure.hex(4)}.txt")
      fetched = PluginSpecHelper.tmp_path("ssm-fetched-#{Random::Secure.hex(4)}.txt")
      status, output = run_ssm_playbook(gateway, <<-YAML)
        - hosts: ssm-target
          gather_facts: false
          tasks:
            - name: copy a file to the target
              copy: {content: "hello ssm\\n", dest: #{remote}, mode: "0644"}
            - name: fetch it back
              fetch: {src: #{remote}, dest: #{fetched}, flat: true}
            - name: stat the target copy
              stat: {path: #{remote}}
              register: st
            - assert:
                that:
                  - st.stat.exists
                  - st.stat.size == 10
        YAML

      assert status.success?, output
      File.read(fetched).must_equal("hello ssm\n")
      File.read(remote).must_equal("hello ssm\n")
    ensure
      delete_ssm_files(remote, fetched) if remote && fetched
    end
  end

  it "runs batching, loops and handlers through the one session" do
    with_ssm_gateway do |gateway|
      status, output = run_ssm_playbook(gateway, <<-YAML)
        - hosts: ssm-target
          gather_facts: false
          tasks:
            - name: first
              command: echo one
              register: one
            - name: second
              command: echo two
              register: two
            - name: third
              command: echo three
              register: three
            - name: loop over items
              command: "echo item-{{ item }}"
              loop: [1, 2, 3]
              register: looped
            - name: notify a handler
              command: echo notify
              changed_when: true
              notify: show handler
            - assert:
                that:
                  - one.stdout == "one"
                  - two.stdout == "two"
                  - three.stdout == "three"
                  - looped.results | length == 3
          handlers:
            - name: show handler
              debug: {msg: "HANDLER-RAN"}
        YAML

      assert status.success?, output
      assert_includes output, "HANDLER-RAN"
      assert_includes output, "failed=0"
    end
  end

  it "reports check mode and diff without writing the target file" do
    with_ssm_gateway do |gateway|
      remote = PluginSpecHelper.tmp_path("ssm-check-#{Random::Secure.hex(4)}.txt")
      File.write(remote, "original\n")
      status, output = run_ssm_playbook(gateway, <<-YAML, cli_args: ["--check", "--diff"])
        - hosts: ssm-target
          gather_facts: false
          tasks:
            - name: copy would change the file
              copy: {content: "changed\\n", dest: #{remote}}
              register: cp
            - assert: {that: ["cp.changed"]}
        YAML

      assert status.success?, output
      File.read(remote).must_equal("original\n")
      assert_includes output, "changed=1"
    ensure
      delete_ssm_files(remote) if remote
    end
  end

  it "delegates an SSM task to a local host" do
    with_ssm_gateway do |gateway|
      status, output = run_ssm_playbook(gateway, <<-YAML)
        - hosts: ssm-target
          gather_facts: false
          tasks:
            - name: delegate to localhost
              command: echo DELEGATED
              delegate_to: localhost
              register: d
            - assert: {that: ["d.stdout == 'DELEGATED'"]}
        YAML

      assert status.success?, output
    end
  end

  # Issue #1693: async: works over aws_ssm. The launch is the same one the
  # ssh path uses (nohup + setsid when the target has it, stdin from
  # /dev/null, a synchronous started: 1 stub), and the poll reads the
  # status file back through the same live session. This is safe because a
  # live run on a real target showed the agent does not reap a detached
  # child when the session is terminated.
  it "runs an async task with poll over SSM" do
    home = PluginSpecHelper.tmp_path("ssm-async-home")
    Dir.mkdir_p(home)
    # The fake agent's pty shell needs the same HOME the controller-side
    # child gets, so ~/.ansible_async is one per-test directory on both
    # sides of the session instead of the host-wide one.
    options = KrikriAwsSsm::Testing::FakeAgent::Options.new
    options.shell_env = {"HOME" => home}
    playbook = <<-YAML
      - hosts: ssm-target
        gather_facts: false
        tasks:
          - name: async job over SSM
            shell: "sleep 2; echo ASYNC-DONE"
            async: 30
            poll: 1
            register: job
          - name: show the job output
            debug: {msg: "{{ job.stdout }}"}
      YAML

    with_ssm_gateway(options) do |gateway|
      status, output = run_ssm_playbook(gateway, playbook,
        env: ssm_child_env.merge({"HOME" => home}))

      assert status.success?, output
      assert_includes output, "ASYNC OK on ssm-target: jid=j"
      assert_includes output, "ASYNC-DONE"
      assert_includes output, "ok=2"

      # The args file carries the full module params and the remote
      # launch creates it under umask 077; a 0644 file here is the
      # pre-fix leak (module params readable by every user on the
      # target).
      jid = output[/ASYNC OK on ssm-target: jid=(\S+)/, 1]
      refute_nil jid, output
      config = File.join(home, ".ansible_async", "#{jid}.config.json")
      assert File.exists?(config), "the launch should leave the job's args file in ~/.ansible_async"
      assert_equal 0o600, (File.info(config).permissions.value & 0o777)
    end
  ensure
    FileUtils.rm_rf(home) if home
  end

  # The fire-and-forget half: poll: 0 returns at once, the detached worker
  # keeps running after that task and after the session's shell goes idle,
  # and a later async_status: task finds it (the ssh semantics, which the
  # live spike says the agent permits over SSM too).
  it "keeps a poll: 0 job running for a later async_status task" do
    home = PluginSpecHelper.tmp_path("ssm-async-home")
    Dir.mkdir_p(home)
    options = KrikriAwsSsm::Testing::FakeAgent::Options.new
    options.shell_env = {"HOME" => home}
    playbook = <<-YAML
      - hosts: ssm-target
        gather_facts: false
        tasks:
          - name: launch without waiting
            shell: "sleep 2; echo ASYNC-LATE"
            async: 30
            poll: 0
            register: launched
          - name: wait for the job
            async_status:
              jid: "{{ launched.ansible_job_id }}"
            register: job
            until: job.finished
            retries: 30
            delay: 1
          - name: show the job output
            debug: {msg: "{{ job.stdout }}"}
          - name: clean up the job
            async_status:
              jid: "{{ launched.ansible_job_id }}"
              mode: cleanup
      YAML

    with_ssm_gateway(options) do |gateway|
      status, output = run_ssm_playbook(gateway, playbook,
        env: ssm_child_env.merge({"HOME" => home}))

      assert status.success?, output
      assert_includes output, "ASYNC-LATE"
      assert_includes output, "ok=4"
      leftover = Dir.glob(File.join(home, ".ansible_async", "j*"))
      assert leftover.empty?,
        "async_status mode: cleanup left #{leftover.inspect} behind on the target\n#{output}"
    end
  ensure
    FileUtils.rm_rf(home) if home
  end

  it "refuses synchronize with a documented message" do
    with_ssm_gateway do |gateway|
      status, output = run_ssm_playbook(gateway, <<-YAML)
        - hosts: ssm-target
          gather_facts: false
          tasks:
            - name: synchronize is unsupported
              synchronize: {src: /tmp/, dest: /tmp/ssm-sync-dest/}
        YAML

      status.success?.must_equal(false)
      assert_includes output, Krikri::SsmSettings::SYNCHRONIZE_UNSUPPORTED_MESSAGE
      output.wont_include("rsync")
    end
  end

  it "refuses a Windows-flavoured target before opening a session" do
    with_ssm_gateway do |gateway|
      status, output = run_ssm_playbook(gateway, <<-YAML, inventory_vars: "ansible_shell_type=powershell")
        - hosts: ssm-target
          gather_facts: false
          tasks:
            - name: a Windows target cannot be driven
              command: echo nope
        YAML

      status.success?.must_equal(false)
      assert_includes output, Krikri::SsmSettings::WINDOWS_UNSUPPORTED_MESSAGE
      assert_includes output, "unreachable=1"
      # The refusal never dialled ssh, so it must not carry ssh's lead.
      output.wont_include("reached over ssh")
    end
  end

  it "maps TargetNotConnected to an actionable UNREACHABLE" do
    with_ssm_gateway do |gateway|
      gateway.control_failure = {400,
                                 %({"__type":"TargetNotConnected","message":"i-0123456789 is not connected"})}
      status, output = run_ssm_playbook(gateway, <<-YAML)
        - hosts: ssm-target
          gather_facts: false
          tasks:
            - command: echo never
        YAML

      status.success?.must_equal(false)
      assert_includes output, Krikri::SsmUnreachableMsg::TARGET_NOT_CONNECTED
      assert_includes output, "unreachable=1"
    end
  end

  it "maps AccessDenied to an actionable UNREACHABLE" do
    with_ssm_gateway do |gateway|
      gateway.control_failure = {400,
                                 %({"__type":"AccessDeniedException","message":"User is not authorized to perform ssm:StartSession"})}
      status, output = run_ssm_playbook(gateway, <<-YAML)
        - hosts: ssm-target
          gather_facts: false
          tasks:
            - command: echo never
        YAML

      status.success?.must_equal(false)
      assert_includes output, Krikri::SsmUnreachableMsg::ACCESS_DENIED
      assert_includes output, "unreachable=1"
    end
  end

  it "reports missing credentials with the documented text" do
    with_ssm_gateway do |gateway|
      empty_home = PluginSpecHelper.tmp_path("ssm-home-#{Random::Secure.hex(4)}")
      Dir.mkdir_p(empty_home)
      env = ssm_child_env.reject { |name, _| name.starts_with?("AWS_ACCESS_KEY") || name.starts_with?("AWS_SECRET") || name.starts_with?("AWS_SESSION") }
      env["HOME"] = empty_home

      status, output = run_ssm_playbook(gateway, <<-YAML, env: env)
        - hosts: ssm-target
          gather_facts: false
          tasks:
            - command: echo never
        YAML

      status.success?.must_equal(false)
      assert_includes output, Krikri::SsmUnreachableMsg::NO_CREDENTIALS
    ensure
      FileUtils.rm_rf(empty_home) if empty_home
    end
  end

  it "fails the task when the session drops mid-run" do
    with_ssm_gateway do |gateway|
      playbook, inventory = write_ssm_files(gateway, <<-YAML, "")
        - hosts: ssm-target
          gather_facts: false
          tasks:
            - name: run long enough to be interrupted
              command: sleep 5
        YAML

      output = IO::Memory.new
      status = Channel(Process::Status).new(1)
      spawn do
        status.send(Process.run(BINARY, ["-i", inventory, playbook],
          input: IO::Memory.new, output: output, error: output, env: ssm_child_env))
      end

      agent = select
      when received = gateway.agents.receive
        received
      when timeout(30.seconds)
        raise "the session never opened"
      end
      # Give the command a moment to reach the shell, then kill the socket
      # without a close frame the way a dropped network path does.
      sleep 2.seconds
      agent.abrupt_close

      final = select
      when received = status.receive
        received
      when timeout(120.seconds)
        raise "the playbook did not finish after the session dropped"
      end

      text = output.to_s
      final.success?.must_equal(false)
      assert_includes text, "UNREACHABLE"
    ensure
      delete_ssm_files(playbook, inventory) if playbook && inventory
    end
  end

  it "runs become through the sudo wrapper" do
    fake_bin = PluginSpecHelper.tmp_path("ssm-fakebin-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(fake_bin)
    sudo = File.join(fake_bin, "sudo")
    File.write(sudo, <<-SH)
      #!/bin/sh
      while [ $# -gt 0 ]; do
        case "$1" in
          -p|-u) shift 2 ;;
          -n|-H|-S|-E|--) shift ;;
          -*) shift ;;
          *) break ;;
        esac
      done
      export FAKE_SUDO=1
      exec "$@"
      SH
    File.chmod(sudo, 0o755)
    options = KrikriAwsSsm::Testing::FakeAgent::Options.new
    options.shell_env = {"PATH" => "#{fake_bin}:#{ENV["PATH"]?}"}

    with_ssm_gateway(options) do |gateway|
      status, output = run_ssm_playbook(gateway, <<-YAML)
        - hosts: ssm-target
          gather_facts: false
          become: true
          tasks:
            - name: the plugin ran through sudo
              shell: echo "become=$FAKE_SUDO"
              register: escalated
            - assert: {that: ["escalated.stdout == 'become=1'"]}
        YAML

      assert status.success?, output
      assert_includes output, "ok=2"
    end
  ensure
    FileUtils.rm_rf(fake_bin) if fake_bin
  end

  # The become-password launch is a different branch of
  # execute_remote_async: the plugin invocation is written to
  # ~/.ansible_async/<jid>.run and run through `sh`, and that file holds
  # the password in plaintext. Pin both that the branch works over the
  # pty session and that the password file is not world-readable.
  it "runs an async task with a become password over SSM" do
    home = PluginSpecHelper.tmp_path("ssm-async-home")
    fake_bin = PluginSpecHelper.tmp_path("ssm-fakebin-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(home)
    Dir.mkdir_p(fake_bin)
    sudo = File.join(fake_bin, "sudo")
    File.write(sudo, <<-SH)
      #!/bin/sh
      while [ $# -gt 0 ]; do
        case "$1" in
          -p|-u) shift 2 ;;
          -n|-H|-S|-E|--) shift ;;
          -*) shift ;;
          *) break ;;
        esac
      done
      exec "$@"
      SH
    File.chmod(sudo, 0o755)
    options = KrikriAwsSsm::Testing::FakeAgent::Options.new
    options.shell_env = {"PATH" => "#{fake_bin}:#{ENV["PATH"]?}", "HOME" => home}
    playbook = <<-YAML
      - hosts: ssm-target
        gather_facts: false
        become: true
        tasks:
          - name: async job through sudo
            shell: "sleep 2; echo BECOME-ASYNC-DONE"
            async: 30
            poll: 1
            register: job
          - name: show the job output
            debug: {msg: "{{ job.stdout }}"}
      YAML

    with_ssm_gateway(options) do |gateway|
      status, output = run_ssm_playbook(gateway, playbook,
        inventory_vars: "ansible_become_password=ssm-become-secret",
        env: ssm_child_env.merge({"HOME" => home}))

      assert status.success?, output
      assert_includes output, "ASYNC OK on ssm-target: jid=j"
      assert_includes output, "BECOME-ASYNC-DONE"
      assert_includes output, "ok=2"

      jid = output[/ASYNC OK on ssm-target: jid=(\S+)/, 1]
      refute_nil jid, output
      run_file = File.join(home, ".ansible_async", "#{jid}.run")
      assert File.exists?(run_file), "the become-password launch should write the .run wrapper"
      assert_equal 0o600, (File.info(run_file).permissions.value & 0o777)
      assert_equal 0o600,
        (File.info(File.join(home, ".ansible_async", "#{jid}.config.json")).permissions.value & 0o777)
    end
  ensure
    FileUtils.rm_rf(fake_bin) if fake_bin
    FileUtils.rm_rf(home) if home
  end
end
