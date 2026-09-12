require "../spec_helper"
require "http/server"

# ansible.builtin.apt_key was entirely unimplemented before - found via
# cloudalchemy.grafana's own "Import Grafana GPG signing key" task,
# which apt-key add's a key fetched from a url:.
#
# Read-only against the real system apt-key keyring in the sense that
# it doesn't assume anything about pre-existing keys - it only checks
# for the presence of a fake, spec-only key ID that can't collide with
# a real one.
FAKE_KEY_ID   = "DEADBEEFCAFEF00D"
FAKE_KEY_BODY = "not a real GPG key, just spec fixture content\n"

apt_key_test_server = HTTP::Server.new do |context|
  case context.request.path
  when "/key.asc"
    context.response.status_code = 200
    context.response.print(FAKE_KEY_BODY)
  else
    context.response.status_code = 404
  end
end
apt_key_test_address = apt_key_test_server.bind_unused_port
spawn { apt_key_test_server.listen }
Fiber.yield

apt_key_base = "http://#{apt_key_test_address}"

VALID_KEY_ASC   = File.read(File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "fixtures", "apt_key_spec_valid_key.asc"))
EXPIRED_KEY_ASC = File.read(File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "fixtures", "apt_key_spec_expired_key.asc"))

# Minimal apt-key double: no real apt-key binary on this dev machine
# (and a real one would mutate the actual system keyring), so the
# post-add verification flow (round 83166) is exercised against this.
# State ("keys already listed") lives in $KRIKRI_APT_KEY_STATE. The add
# branch mirrors the real one's expired-key quirk that motivated the
# fix: gpg marks an expired key's pub line with validity field 'e', and
# real `apt-key add` prints OK and exits 0 even though the key never
# becomes visible to a later listing.
APT_KEY_SHIM = <<-'SH'
#!/bin/bash
STATE="${KRIKRI_APT_KEY_STATE:?}"
args=("$@")
for i in "${!args[@]}"; do
  case "${args[$i]}" in
    adv)
      rest=("${args[@]:$((i+1))}")
      if [[ "${rest[*]}" == *--list-public-keys* ]]; then
        [ -f "$STATE" ] && cat "$STATE"
        exit 0
      fi
      ;;
    add)
      f="${args[$((i+1))]}"
      parsed=$(gpg --with-colons "$f" 2>/dev/null | awk -F: '$1=="pub"{print $2" "$5; exit}')
      validity="${parsed%% *}" key_id="${parsed##* }"
      if [ -n "$key_id" ] && [ "$validity" != "e" ]; then
        echo "pub  2048R/$key_id 2020-01-01" >> "$STATE"
      fi
      echo OK
      exit 0
      ;;
  esac
done
exit 1
SH

# Installs the apt-key double at the front of PATH for the block's
# duration; the plugin's local remote_exec shells out via bash and
# inherits the spec process's environment.
def with_apt_key_shim(state_file : String, &)
  shim_dir = File.tempname("/tmp", ".krikri-spec-aptkey-shim")
  shim = File.join(shim_dir, "apt-key")
  Dir.mkdir(shim_dir)
  File.write(shim, APT_KEY_SHIM)
  File.chmod(shim, 0o755)
  old_path = ENV["PATH"]?
  ENV["PATH"] = "#{shim_dir}:#{old_path}"
  ENV["KRIKRI_APT_KEY_STATE"] = state_file
  yield
ensure
  ENV["PATH"] = old_path if old_path
  ENV.delete("KRIKRI_APT_KEY_STATE")
  File.delete(shim.not_nil!) rescue nil
  Dir.delete(shim_dir.not_nil!) rescue nil
end

def apt_key_spec_state_file : String
  File.tempname("/tmp", ".krikri-spec-aptkey-state")
end

describe "apt_key plugin" do
  it "fails when more than one of data:/file:/keyserver:/url: is given, matching real Ansible's exact message" do
    # Real apt_key.py's argument_spec declares mutually_exclusive=
    # (('data', 'file', 'keyserver', 'url'),) and validates it BEFORE
    # main() runs anything. Live-verified against ansible-core 2.19.4
    # with a local-connection playbook: the message is the whole
    # declaration-order tuple joined by |, regardless of which of the
    # four were given.
    result = PluginSpecHelper.run("apt_key", {"state" => "present", "url" => "https://example.com/key.gpg", "data" => VALID_KEY_ASC})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are mutually exclusive: data|file|keyserver|url")
  end

  it "counts an explicitly empty param as given for the mutual-exclusion check (matches real Ansible's key-presence semantics)" do
    # Real check_mutually_exclusive -> count_terms counts param KEYS
    # (set(terms).intersection(parameters)), not truthy values, so
    # url: "" + data: still fails - live-verified against ansible-core
    # 2.19.4.
    result = PluginSpecHelper.run("apt_key", {"state" => "present", "url" => "", "data" => VALID_KEY_ASC})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are mutually exclusive: data|file|keyserver|url")
  end

  it "requires url or data when adding a key" do
    result = PluginSpecHelper.run("apt_key", {"state" => "present"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("url or data")
  end

  it "requires id when removing a key" do
    result = PluginSpecHelper.run("apt_key", {"state" => "absent"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("id")
  end

  it "reports already-absent as unchanged for a key id that was never added" do
    result = PluginSpecHelper.run("apt_key", {"state" => "absent", "id" => FAKE_KEY_ID})

    result["changed"].as_bool.should be_false
    result["failed"].as_bool.should be_false
  end

  it "requires id when keyserver: is given, matching real Ansible's exact message" do
    # Real bug found via a proactive scope-cut audit: keyserver: was
    # entirely unimplemented. Verified against real
    # ansible/modules/apt_key.py's own source - `if not key_id: if
    # keyserver: module.fail_json(msg="Missing key_id, required with
    # keyserver.")` - matched verbatim, not paraphrased. A real fetch
    # (`apt-key adv --keyserver ... --recv ...`) needs network access
    # and a real apt-key binary (not installed on this dev machine
    # either), so only the validation path is exercised here.
    result = PluginSpecHelper.run("apt_key", {"state" => "present", "keyserver" => "keyserver.ubuntu.com"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Missing key_id, required with keyserver.")
  end

  it "fetches url: via curl (not Crystal's own HTTP::Client) and reaches apt-key add, not a crash" do
    # Real bug: Crystal's own HTTP::Client silently truncated chunked-
    # transfer-encoded HTTPS response bodies for at least one real key
    # server (pkgs.tailscale.com) - 200 OK, no error, but a partial
    # body, which gpg/apt-key then correctly rejected as invalid key
    # material. Switched url: fetching to shell out to curl instead
    # (this dev machine has curl but no real apt-key binary, so this
    # confirms the fetch itself succeeds and the plugin reaches - and
    # fails cleanly at - the apt-key add step, not a truncated-body
    # false negative or a crash).
    result = PluginSpecHelper.run("apt_key", {"state" => "present", "url" => "#{apt_key_base}/key.asc"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should_not contain("Failed to fetch key")
  end

  it "attempts a real keyserver fetch (and fails cleanly, not a crash) when id: is given but not yet present" do
    # This dev machine has no real apt-key binary or network access for
    # a real fetch, so this only confirms the plugin reaches and
    # attempts the keyserver: command path (rather than skipping it or
    # crashing) - fails with a clear "Error fetching key" message
    # instead of an unhandled exception either way. The pre-add listing
    # (real Ansible's all_keys, added with the round 83166 fix) runs
    # against the apt-key double; its --recv path is left failing.
    state = apt_key_spec_state_file
    with_apt_key_shim(state) do
      result = PluginSpecHelper.run("apt_key", {"state" => "present", "keyserver" => "keyserver.ubuntu.com", "id" => FAKE_KEY_ID})

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should contain("Error fetching key")
    end
    File.delete(state) rescue nil
  end

  it "requires no key material when keyserver: + id: are given (url/data/file are alternatives, not prerequisites)" do
    # Regression: the round 83166 rework of #add_key initially required
    # url:/data:/file: even on the keyserver: path, breaking
    # keyserver+id (real Ansible's --recv needs neither). The double
    # fails --recv, so reaching "Error fetching key" proves the flow
    # got past the material check instead of failing earlier.
    state = apt_key_spec_state_file
    with_apt_key_shim(state) do
      result = PluginSpecHelper.run("apt_key", {"state" => "present", "keyserver" => "keyserver.ubuntu.com", "id" => FAKE_KEY_ID})

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should contain("Error fetching key")
    end
    File.delete(state) rescue nil
  end

  it "adds data: key material end to end and converges (changed on first run, unchanged on the second)" do
    # Round 83166 flow: with no id:, the key id is derived from the
    # material itself (gpg --with-colons), checked against the listing,
    # added, and VERIFIED in the listing afterwards. The fixture key's
    # id is E07A3F141278AEBD. Also pins the idempotency result: a key
    # already present must report changed: false (the rework initially
    # lost that and reported changed: true on every run).
    state = apt_key_spec_state_file
    with_apt_key_shim(state) do
      result = PluginSpecHelper.run("apt_key", {"state" => "present", "data" => VALID_KEY_ASC})

      result["changed"].as_bool.should be_true
      result["failed"].as_bool.should be_false

      result2 = PluginSpecHelper.run("apt_key", {"state" => "present", "data" => VALID_KEY_ASC})

      result2["changed"].as_bool.should be_false
      result2["failed"].as_bool.should be_false
    end
    File.delete(state) rescue nil
  end

  it "fails with real Ansible's post-add verification message when the add exits 0 but the key never lands in the listing (round 83166, expired key)" do
    # The actual acandid.jenkins failure mode: its key material is an
    # EXPIRED signing key. Derivation from the colon format still
    # yields the id (real Ansible's word-based "expired" filter only
    # matches the human-format listing), the add prints OK and exits
    # 0, but the expired key never shows up in the listing - so the
    # task must FAIL here rather than report success. The double's add
    # branch reproduces exactly that quirk (expired validity field 'e'
    # in gpg --with-colons output is not recorded).
    state = apt_key_spec_state_file
    with_apt_key_shim(state) do
      result = PluginSpecHelper.run("apt_key", {"state" => "present", "data" => EXPIRED_KEY_ASC})

      result["failed"].as_bool.should be_true
      result["changed"].as_bool.should be_true
      result["msg"].as_s.should eq("apt-key did not return an error, but failed to add the key (check that the id is correct and *not* a subkey)")
    end
    File.delete(state) rescue nil
  end
end
