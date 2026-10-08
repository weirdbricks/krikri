require "../minitest_helper"
require "../../src/krikri/ssh_manager"
require "../../src/krikri/passwords"
require "../../src/krikri/plugin_helpers/synchronize_rsync"

# -k/--ask-pass/--connection-password-file (and an inventory
# ansible_password/ansible_ssh_pass) must reach every ssh/scp/rsync
# spawn as `sshpass -e`, with the password itself NEVER on any argv -
# only in the child's SSHPASS environment. All of this is pure command
# construction: no ssh, scp or rsync process is ever started here.
describe "SSHManager sshpass wrapping (sshpass_wrapping_test.cr)" do
  serial! # mutates process-global sshpass-availability/password-registry state

  describe ".ssh_argv" do
    it "runs plain ssh with no sshpass when no password is set" do
      argv = Krikri::SSHManager.ssh_argv("/tmp/.krikri-playbook-ssh/cp", nil, 22, "root", "192.0.2.1", ["/bin/bash -c 'true'"])
      argv.first.must_equal("ssh")
      argv.includes?("sshpass").must_equal(false)
      argv.includes?("root@192.0.2.1").must_equal(true)
      argv.includes?("-p").must_equal(true)
      argv.last.must_equal("/bin/bash -c 'true'")
    end

    it "prefixes sshpass -e when a password is set, without the password itself" do
      Krikri::SSHManager.sshpass_available_for_spec = true
      begin
        password = "s3cr3t-value"
        argv = Krikri::SSHManager.ssh_argv("/tmp/cp", nil, nil, "root", "192.0.2.1", ["bash", "-s"], password)
        argv[0].must_equal("sshpass")
        argv[1].must_equal("-e")
        argv[2].must_equal("ssh")
        argv.includes?("-p").must_equal(false) # nil port still omits -p
        argv.any? { |arg| arg.includes?(password) }.must_equal(false)
      ensure
        Krikri::SSHManager.sshpass_available_for_spec = nil
      end
    end

    it "runs unwrapped ssh with the askpass single-prompt option when a password is set but sshpass is missing" do
      Krikri::SSHManager.sshpass_available_for_spec = false
      begin
        password = "s3cr3t-value"
        argv = Krikri::SSHManager.ssh_argv("/tmp/cp", nil, nil, "root", "192.0.2.1", ["bash", "-s"], password)
        argv[0].must_equal("ssh")
        argv.includes?("sshpass").must_equal(false)
        argv.includes?("NumberOfPasswordPrompts=1").must_equal(true)
        argv.any? { |arg| arg.includes?(password) }.must_equal(false)
      ensure
        Krikri::SSHManager.sshpass_available_for_spec = nil
      end
    end
  end

  describe ".scp_argv" do
    it "wraps scp the same way, keeping the upload/download shapes intact" do
      Krikri::SSHManager.sshpass_available_for_spec = true
      begin
        upload = Krikri::SSHManager.scp_argv("/tmp/cp", nil, 22, "root", "h", ["/l", "h:/r"], recursive: true, connect_timeout: true, password: "pw")
        upload[0].must_equal("sshpass")
        upload.includes?("-e").must_equal(true)
        upload.includes?("scp").must_equal(true)
        upload.includes?("-r").must_equal(true)
        upload.includes?("ConnectTimeout=#{Krikri::CliOptions.timeout}").must_equal(true)
        upload.any? { |arg| arg.includes?("pw") }.must_equal(false)
      ensure
        Krikri::SSHManager.sshpass_available_for_spec = nil
      end

      download = Krikri::SSHManager.scp_argv("/tmp/cp", nil, nil, "root", "h", ["h:/r", "/l"], recursive: false, connect_timeout: false)
      download.first.must_equal("scp")
      download.includes?("-r").must_equal(false)
      download.includes?("ConnectTimeout=#{Krikri::CliOptions.timeout}").must_equal(false)
    end

    it "leaves scp unwrapped with the askpass option when a password is set but sshpass is missing" do
      Krikri::SSHManager.sshpass_available_for_spec = false
      begin
        upload = Krikri::SSHManager.scp_argv("/tmp/cp", nil, 22, "root", "h", ["/l", "h:/r"], recursive: true, connect_timeout: true, password: "pw")
        upload[0].must_equal("scp")
        upload.includes?("sshpass").must_equal(false)
        upload.includes?("NumberOfPasswordPrompts=1").must_equal(true)
        upload.any? { |arg| arg.includes?("pw") }.must_equal(false)
      ensure
        Krikri::SSHManager.sshpass_available_for_spec = nil
      end
    end
  end

  describe ".rsync_ssh_command" do
    it "wraps the -e ssh command in sshpass -e when a password is set" do
      plain = Krikri::SSHManager.rsync_ssh_command("/tmp/cp", nil, nil)
      plain.starts_with?("ssh -o ControlMaster=auto").must_equal(true)
      plain.includes?("sshpass").must_equal(false)

      Krikri::SSHManager.sshpass_available_for_spec = true
      begin
        wrapped = Krikri::SSHManager.rsync_ssh_command("/tmp/cp", nil, nil, "pw123")
        wrapped.starts_with?("sshpass -e ssh -o ControlMaster=auto").must_equal(true)
        wrapped.includes?("pw123").must_equal(false)
      ensure
        Krikri::SSHManager.sshpass_available_for_spec = nil
      end
    end

    it "leaves the -e ssh command unwrapped with the askpass option when a password is set but sshpass is missing" do
      Krikri::SSHManager.sshpass_available_for_spec = false
      begin
        wrapped = Krikri::SSHManager.rsync_ssh_command("/tmp/cp", nil, nil, "pw123")
        wrapped.starts_with?("ssh -o ControlMaster=auto").must_equal(true)
        wrapped.includes?("NumberOfPasswordPrompts=1").must_equal(true)
        wrapped.includes?("sshpass").must_equal(false)
        wrapped.includes?("pw123").must_equal(false)
      ensure
        Krikri::SSHManager.sshpass_available_for_spec = nil
      end
    end
  end

  describe "sshpass plumbing" do
    it "hands the password to sshpass only via SSHPASS" do
      Krikri::SSHManager.sshpass_available_for_spec = true
      begin
        Krikri::SSHManager.sshpass_env(nil).must_be_nil
        env = Krikri::SSHManager.sshpass_env("hunter2")
        env.nil?.must_equal(false)
        (env || {} of String => String)["SSHPASS"].must_equal("hunter2")
        Krikri::SSHManager.sshpass_prefix(nil).must_equal([] of String)
        Krikri::SSHManager.sshpass_prefix("x").must_equal(["sshpass", "-e"])
      ensure
        Krikri::SSHManager.sshpass_available_for_spec = nil
      end
    end

    it "registers the password anyway when sshpass is missing (askpass fallback, no raise)" do
      Krikri::SSHManager.sshpass_available_for_spec = false
      begin
        Krikri::SSHManager.register_connection_password("192.0.2.1", "root", 22, "pw")
        Krikri::SSHManager.password_for("192.0.2.1", "root", 22).must_equal("pw")
        Krikri::SSHManager.sshpass_prefix("pw").must_equal([] of String)
      ensure
        Krikri::SSHManager.clear_connection_passwords_for_spec
        Krikri::SSHManager.sshpass_available_for_spec = nil
      end
    end

    it "builds the askpass env overlay when a password is set but sshpass is missing" do
      Krikri::SSHManager.sshpass_available_for_spec = false
      begin
        env = Krikri::SSHManager.sshpass_env("hunter2")
        env.nil?.must_equal(false)
        overlay = env || {} of String => String
        overlay["SSHPASS"].must_equal("hunter2")
        overlay["SSH_ASKPASS_REQUIRE"].must_equal("force")
        overlay["SSH_ASKPASS"].must_equal(Krikri::SSHManager.askpass_helper_path)
        if ENV.has_key?("DISPLAY")
          overlay.has_key?("DISPLAY").must_equal(false)
        else
          overlay["DISPLAY"].must_equal("-")
        end
      ensure
        Krikri::SSHManager.sshpass_available_for_spec = nil
      end
    end

    it "keeps the askpass helper env-only: file exists, is owner-executable, and never embeds the password" do
      path = Krikri::SSHManager.askpass_helper_path
      File.exists?(path).must_equal(true)
      (File.info(path).permissions.value & 0o100).must_equal(0o100)
      content = File.read(path)
      content.starts_with?("#!/bin/sh").must_equal(true)
      content.includes?("SSHPASS").must_equal(true)
      content.includes?("hunter2").must_equal(false)
      content.includes?("s3cr3t").must_equal(false)
    end

    it "round-trips a registered password and treats nil as a no-op" do
      # Pinned true: this machine may not have sshpass installed, and
      # this test is about the registry, not the availability probe.
      Krikri::SSHManager.sshpass_available_for_spec = true
      begin
        Krikri::SSHManager.register_connection_password("192.0.2.1", "root", 22, "pw-a")
        Krikri::SSHManager.register_connection_password("192.0.2.1", "root", 22, nil) # must not erase
        Krikri::SSHManager.password_for("192.0.2.1", "root", 22).must_equal("pw-a")
        Krikri::SSHManager.password_for("192.0.2.1", "root", 2222).must_be_nil # port keys separately
        Krikri::SSHManager.password_for("other", "root", 22).must_be_nil
      ensure
        Krikri::SSHManager.clear_connection_passwords_for_spec
        Krikri::SSHManager.sshpass_available_for_spec = nil
      end
    end
  end
end

# The controller-side synchronize action plugin passes SSHManager's
# sshpass availability into the rsh decision, so a password with no
# sshpass leaves the rsh ssh unwrapped (it inherits the askpass overlay
# from the run env) instead of pointing at a missing sshpass binary.
describe "SynchronizeRsync rsh sshpass decision (sshpass_wrapping_test.cr)" do
  it "wraps the rsh ssh in sshpass -e by default and unwraps it on the askpass path" do
    params = {} of String => String
    wrapped = Krikri::SynchronizeRsync.build_argv("/tmp/src", "root@h:/tmp/dest", params, password: "pw")
    rsh = wrapped.find(&.starts_with?("--rsh="))
    rsh.nil?.must_equal(false)
    (rsh || "").includes?("sshpass -e ssh -S none").must_equal(true)

    unwrapped = Krikri::SynchronizeRsync.build_argv("/tmp/src", "root@h:/tmp/dest", params, password: "pw", wrap_rsh_sshpass: false)
    rsh2 = unwrapped.find(&.starts_with?("--rsh="))
    (rsh2 || "").includes?("sshpass").must_equal(false)
    (rsh2 || "").includes?("ssh -S none").must_equal(true)

    no_password = Krikri::SynchronizeRsync.build_argv("/tmp/src", "root@h:/tmp/dest", params)
    rsh3 = no_password.find(&.starts_with?("--rsh="))
    (rsh3 || "").includes?("sshpass").must_equal(false)
  end
end

# The shared key resolution both entry points and every dispatch site
# use, so -k/-K/--*-password-file and the inventory spellings all land
# on the same variable names ansible-core itself reads.
describe "Krikri::Passwords resolution (sshpass_wrapping_test.cr)" do
  it "reads the connection password from every ansible ssh spelling" do
    Krikri::Passwords.connection({"ansible_password" => JSON::Any.new("a")}).must_equal("a")
    Krikri::Passwords.connection({"ansible_ssh_pass" => JSON::Any.new("b")}).must_equal("b")
    Krikri::Passwords.connection({"ansible_ssh_password" => JSON::Any.new("c")}).must_equal("c")
  end

  it "prefers task vars over inventory vars and skips empty/null values" do
    host = Krikri::Host.new("web1")
    host.vars["ansible_password"] = JSON::Any.new("inventory-pw")
    Krikri::Passwords.connection(nil, host).must_equal("inventory-pw")
    Krikri::Passwords.connection({"ansible_password" => JSON::Any.new("task-pw")}, host).must_equal("task-pw")
    Krikri::Passwords.connection({"ansible_password" => JSON::Any.new("")}, host).must_equal("inventory-pw")
    Krikri::Passwords.connection({"ansible_password" => JSON::Any.new(nil)}, host).must_equal("inventory-pw")
    Krikri::Passwords.connection(nil, nil).must_be_nil
  end

  it "reads the become password from every ansible sudo spelling" do
    Krikri::Passwords.become({"ansible_become_password" => JSON::Any.new("a")}).must_equal("a")
    Krikri::Passwords.become({"ansible_become_pass" => JSON::Any.new("b")}).must_equal("b")
    Krikri::Passwords.become({"ansible_sudo_pass" => JSON::Any.new("c")}).must_equal("c")
    Krikri::Passwords.become(nil).must_be_nil
  end
end
