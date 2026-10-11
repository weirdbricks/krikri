require "../minitest_helper"
require "../../src/krikri/connection_settings"
require "../../src/krikri/task_batcher"
require "../../src/krikri/playbook_parser"

private def conn_host(name : String, user : String? = nil, port : Int32? = nil,
                      vars : Hash(String, JSON::Any) = Hash(String, JSON::Any).new) : Krikri::Host
  host = Krikri::Host.new(name, user, port)
  host.vars = vars
  host
end

private def jv(value : String) : JSON::Any
  JSON::Any.new(value)
end

describe Krikri::ConnectionSettings do
  it "falls back to the host's inventory identity when no connection vars are set" do
    host = conn_host("web1", "admin", 2222)
    conn = Krikri::ConnectionSettings.resolve(host, nil)
    conn.user.must_equal("admin")
    conn.port.must_equal(2222)
    conn.conn_host.must_equal("web1")
    conn.identity_file.must_be_nil
    conn.password.must_be_nil
    conn.common_args.must_equal([] of String)
    conn.extra_args.must_equal([] of String)
  end

  it "takes user/port/host/key/password/args from the task's vars first" do
    host = conn_host("web1", "admin", 2222,
      vars = {
        "ansible_user"                  => jv("invuser"),
        "ansible_port"                  => JSON::Any.new(2223),
        "ansible_host"                  => jv("10.9.8.7"),
        "ansible_ssh_private_key_file"  => jv("/inv/id_rsa"),
        "ansible_ssh_pass"              => jv("invpass"),
        "ansible_ssh_common_args"       => jv("-o A=1"),
        "ansible_ssh_extra_args"        => jv("-o B=2"),
      } of String => JSON::Any)
    task_vars = {
      "ansible_user"                 => jv("taskuser"),
      "ansible_port"                 => JSON::Any.new(2202),
      "ansible_host"                 => jv("10.0.0.9"),
      "ansible_ssh_private_key_file" => jv("/task/id_ed25519"),
      "ansible_ssh_pass"             => jv("taskpass"),
      "ansible_ssh_common_args"      => jv("-o PubkeyAuthentication=no -o C='x y'"),
      "ansible_ssh_extra_args"       => jv("-o D=4"),
    } of String => JSON::Any
    conn = Krikri::ConnectionSettings.resolve(host, task_vars)
    conn.user.must_equal("taskuser")
    conn.port.must_equal(2202)
    conn.conn_host.must_equal("10.0.0.9")
    conn.identity_file.must_equal("/task/id_ed25519")
    conn.password.must_equal("taskpass")
    conn.common_args.must_equal(["-o", "PubkeyAuthentication=no", "-o", "C=x y"])
    conn.extra_args.must_equal(["-o", "D=4"])
    _ = vars
  end

  it "honors the deprecated ansible_ssh_* spellings when the canonical names are absent" do
    host = conn_host("web1", "invuser", 2222)
    conn = Krikri::ConnectionSettings.resolve(host, {
      "ansible_ssh_user" => jv("legacyuser"),
      "ansible_ssh_port" => JSON::Any.new(2203),
      "ansible_ssh_host" => jv("10.0.0.8"),
    } of String => JSON::Any)
    conn.user.must_equal("legacyuser")
    conn.port.must_equal(2203)
    conn.conn_host.must_equal("10.0.0.8")
  end

  it "ignores unrendered template values (the pre-pass's raw-vars view)" do
    host = conn_host("web1", "invuser", 2222)
    conn = Krikri::ConnectionSettings.resolve(host, {
      "ansible_user" => jv("{{ deploy_user }}"),
      "ansible_port" => jv("{{ deploy_port }}"),
    } of String => JSON::Any)
    conn.user.must_equal("invuser")
    conn.port.must_equal(2222)
  end

  it "keys the spec on (user, host, port) the way the upload/daemon caches do" do
    host = conn_host("web1", "invuser", 2222, {"ansible_host" => jv("10.0.0.9")} of String => JSON::Any)
    conn = Krikri::ConnectionSettings.resolve(host, {"ansible_user" => jv("taskuser")} of String => JSON::Any)
    conn.spec_key.must_equal("taskuser@10.0.0.9:2222")
  end

  it "fingerprints differ whenever any connection option differs" do
    host = conn_host("web1", "invuser", 2222)
    a = Krikri::ConnectionSettings.resolve(host, {"ansible_ssh_pass" => jv("pw")} of String => JSON::Any)
    b = Krikri::ConnectionSettings.resolve(host, {"ansible_ssh_pass" => jv("pw"), "ansible_ssh_common_args" => jv("-o X=1")} of String => JSON::Any)
    c = Krikri::ConnectionSettings.resolve(host, {"ansible_ssh_private_key_file" => jv("/k")} of String => JSON::Any)
    a.fingerprint.wont_equal(b.fingerprint)
    a.fingerprint.wont_equal(c.fingerprint)
  end

  describe "resolve_play" do
    it "lets play vars outrank inventory host vars for the connection keys" do
      host = conn_host("web1", "invuser", 2222,
        {
          "ansible_user"  => jv("invuser"),
          "ansible_host"  => jv("10.0.0.1"),
          "ansible_port"  => JSON::Any.new(2222),
          "unrelated_var" => jv("keep"),
        } of String => JSON::Any)
      play_vars = {
        "ansible_user" => jv("playuser"),
        "ansible_port" => JSON::Any.new(2204),
      } of String => JSON::Any
      conn = Krikri::ConnectionSettings.resolve_play(host, play_vars)
      conn.user.must_equal("playuser")
      conn.port.must_equal(2204)
      # The play set no ansible_host - the inventory's must survive.
      conn.conn_host.must_equal("10.0.0.1")
    end

    it "keeps the inventory identity when the play sets nothing" do
      host = conn_host("web1", "invuser", 2222, {"ansible_host" => jv("10.0.0.1")} of String => JSON::Any)
      conn = Krikri::ConnectionSettings.resolve_play(host, {"unrelated" => jv("x")} of String => JSON::Any)
      conn.user.must_equal("invuser")
      conn.port.must_equal(2222)
      conn.conn_host.must_equal("10.0.0.1")
    end
  end

  describe "connection_sig" do
    it "is empty when no options are set" do
      Krikri::SSHManager.connection_sig(nil, [] of String, nil).must_equal("")
    end

    it "differs when the identity file, args, or password presence differ" do
      base = Krikri::SSHManager.connection_sig(nil, [] of String, nil)
      with_key = Krikri::SSHManager.connection_sig("/k", [] of String, nil)
      with_args = Krikri::SSHManager.connection_sig(nil, ["-o", "BatchMode=yes"], nil)
      with_pw = Krikri::SSHManager.connection_sig(nil, [] of String, "pw")
      base.wont_equal(with_key)
      base.wont_equal(with_args)
      base.wont_equal(with_pw)
      Krikri::SSHManager.connection_sig("/k", [] of String, nil)
        .must_equal(Krikri::SSHManager.connection_sig("/k", [] of String, nil))
    end
  end

  describe "split_ssh_args" do
    it "splits plain words and keeps quoted spans (including spaces) intact" do
      Krikri::ConnectionSettings.split_ssh_args("-o A=1 -o 'B=x y' -o \"C=z w\"").must_equal(
        ["-o", "A=1", "-o", "B=x y", "-o", "C=z w"])
    end

    it "handles backslash escapes and empty input" do
      Krikri::ConnectionSettings.split_ssh_args("a\\ b").must_equal(["a b"])
      Krikri::ConnectionSettings.split_ssh_args(nil).must_equal([] of String)
      Krikri::ConnectionSettings.split_ssh_args("").must_equal([] of String)
    end

    it "returns a fresh array per call (no shared-state leaks)" do
      a = Krikri::ConnectionSettings.split_ssh_args("-o X=1")
      b = Krikri::ConnectionSettings.split_ssh_args("-o X=1")
      a.must_equal(b)
      a.wont_be_same_as(b)
    end
  end

  it "lets a play-level connection password outrank the inventory's" do
    host = conn_host("web1", "invuser", 2222,
      {"ansible_ssh_pass" => jv("invpass")} of String => JSON::Any)
    conn = Krikri::ConnectionSettings.resolve_play(host, {"ansible_ssh_pass" => jv("playpass")} of String => JSON::Any)
    conn.password.must_equal("playpass")
  end

  it "fingerprints differ when common_args or extra_args differ" do
    host = conn_host("web1", "invuser", 2222)
    base = Krikri::ConnectionSettings.resolve(host, nil)
    with_common = Krikri::ConnectionSettings.resolve(host, {"ansible_ssh_common_args" => jv("-o X=1")} of String => JSON::Any)
    with_extra = Krikri::ConnectionSettings.resolve(host, {"ansible_ssh_extra_args" => jv("-o Y=2")} of String => JSON::Any)
    base.fingerprint.wont_equal(with_common.fingerprint)
    base.fingerprint.wont_equal(with_extra.fingerprint)
    with_common.fingerprint.wont_equal(with_extra.fingerprint)
  end
end

describe Krikri::SSHManager do
  it "keys daemon unavailability per connection signature, not just (host, user, port, become)" do
    host = "192.0.2.11"
    Krikri::SSHManager.daemon_unavailable?(host, "root", 22, nil, "sigA").must_equal(false)
    Krikri::SSHManager.daemon_unavailable?(host, "root", 22, nil, "sigB").must_equal(false)
    # Marking one signature unavailable must not poison the other.
    process = Process.new("sleep", ["30"])
    Krikri::SSHManager.seed_daemon_process_for_spec(host, "root", 22, nil, process, "sigA")
    Krikri::SSHManager.clear_daemon_for_spec(host, "root", 22, nil, "sigA")
    Krikri::SSHManager.daemon_unavailable?(host, "root", 22, nil, "sigB").must_equal(false)
    Krikri::SSHManager.clear_daemon_for_spec(host, "root", 22, nil, "sigB")
  end
end

describe Krikri::TaskBatcher do
  it "solos a task whose own vars set connection variables" do
    tasks_yaml = <<-YAML
      - name: a
        ansible.builtin.command: echo one
      - name: switch
        ansible.builtin.command: echo two
        vars:
          ansible_user: other
      - name: c
        ansible.builtin.command: echo three
    YAML
    playbook = Krikri::PlaybookParser.parse_string("- hosts: x\n  tasks:\n" + tasks_yaml.split("\n").map { |l| "  #{l}" }.join("\n"))
    groups = Krikri::TaskBatcher.plan(playbook.plays[0].tasks)
    groups.any? { |g| g.map(&.name).includes?("switch") && g.size > 1 }.must_equal(false)
  end
end
