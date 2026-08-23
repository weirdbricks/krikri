#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # Apt_key plugin - imports/removes a GPG key into apt's legacy trusted
  # keyring. Compatible with Ansible's ansible.builtin.apt_key module
  # (deprecated in real ansible-core in favor of signed-by:/deb822_
  # repository, but still shipped and still what plenty of real roles
  # use - verified against real ansible-playbook, which still runs it
  # successfully on ansible-core 2.19.4).
  #
  # Supported parameters:
  # - url: fetch the key from this URL (fetched on the TARGET, matching
  #   real Ansible - apt_key: is never delegated to the controller the
  #   way copy:'s src: implicitly is)
  # - data: the key's own ASCII-armored text, given directly
  # - state: present (default) | absent
  # - id: the key's ID/fingerprint - required for state: absent, and
  #   used to skip re-adding an already-present key for state: present
  # - validate_certs: default true; false skips TLS verification for
  #   url: (grafana's own role sets this)
  #
  # - keyserver: fetches by id: from a keyserver instead of url:/data: -
  #   verified against real ansible/modules/apt_key.py's own source:
  #   `apt-key adv --no-tty --keyserver <keyserver> --recv <id>`, and
  #   REQUIRES id: (real Ansible fails with "Missing key_id, required
  #   with keyserver." otherwise - matched exactly, not silently
  #   defaulted).
  #
  # - keyring: the full path to a specific keyring file (real Ansible
  #   passes this straight through as `apt-key --keyring <path> ...`,
  #   applying to every apt-key subcommand - add/del/list). Previously
  #   entirely unimplemented (every key always went into the legacy
  #   default keyring regardless), which was silently WRONG rather than
  #   just narrower whenever a role's own `apt_repository:`/deb822
  #   `signed-by=` pointed at that same specific keyring path (a very
  #   common modern idiom, since apt deprecated the shared default
  #   keyring) - apt couldn't find the key where the repo config said
  #   it should be, and every subsequent `apt-get update` failed with
  #   "NO_PUBKEY"/"is not signed" even though the key HAD been added
  #   (just to the wrong file). Found benchmarking robertdebock.
  #   tailscale's own `keyring: /usr/share/keyrings/tailscale-archive-
  #   keyring.gpg`.
  class AptKeyPlugin < BasePlugin
    def execute : PluginResult
      state = @params["state"]?.try(&.downcase) || "present"

      if state == "absent"
        return remove_key
      end

      add_key
    end

    private def keyring_flag : String
      keyring = @params["keyring"]?
      keyring ? "--keyring #{keyring} " : ""
    end

    private def add_key : PluginResult
      key_id = @params["id"]?

      if key_id && key_present?(key_id)
        return PluginResult.new(changed: false, failed: false, msg: "Key already present")
      end

      if keyserver = @params["keyserver"]?
        return PluginResult.new(changed: false, failed: true, msg: "Missing key_id, required with keyserver.") unless key_id

        result = remote_exec("apt-key #{keyring_flag}adv --no-tty --keyserver #{keyserver} --recv #{key_id}")
        unless result[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true, msg: "Error fetching key #{key_id} from keyserver: #{result[:stderr]}")
        end

        return PluginResult.new(changed: true, failed: false, msg: "Key added")
      end

      url = @params["url"]?
      data = @params["data"]?
      unless url || data
        return PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: url or data")
      end

      tmp_path = "/tmp/.crystal-ansible-apt-key-#{Random.rand(100000..999999)}"
      begin
        if url
          # Fetched via curl on the TARGET rather than Crystal's own
          # HTTP::Client - a real, reproducible Crystal 1.20.3 stdlib
          # bug truncates chunked-transfer-encoded HTTPS response
          # bodies for at least this real key server (pkgs.tailscale.
          # com), silently returning a partial/corrupt body with no
          # error (fetch "succeeds", 200 OK, but 1399 of the real 2288
          # bytes) - `gpg`/`apt-key add` then correctly rejects the
          # truncated key material as invalid. Confirmed the truncation
          # is deterministic and independent of how the response is
          # consumed (direct `.body`, streaming `.body_io.gets_to_end`,
          # and the top-level `HTTP::Client.get` convenience method all
          # reproduce it identically), and confirmed real `curl` fetches
          # the same URL correctly (byte-for-byte) both from this
          # sandbox and from the live target host - so this shells out
          # to curl instead of trying to work around Crystal's own HTTP
          # client, matching how #add_key's `keyserver:` branch already
          # shells out to `apt-key adv` rather than reimplementing a
          # keyserver protocol client.
          insecure_flag = is_true?(@params["validate_certs"]?, default: true) ? "" : "--insecure "
          result = remote_exec("curl --fail --silent --show-error --location #{insecure_flag}-o #{tmp_path} #{shell_single_quote(url)}")
          unless result[:exit_code] == 0
            return PluginResult.new(changed: false, failed: true, msg: "Failed to fetch key from #{url}: #{result[:stderr]}")
          end
        else
          File.write(tmp_path, data.not_nil!)
        end

        # Real Ansible's apt_key: is idempotent even when only url:/data:
        # is given (no id:) - it derives the key's own fingerprint from
        # the fetched key material itself before deciding whether to
        # import. Previously only the id: param triggered a #key_present?
        # check at all - url:/data: (the overwhelmingly common real-world
        # shape, per this file's own doc comment above) always re-ran
        # `apt-key add` and reported changed: true on every single run,
        # never converging. Found benchmarking geerlingguy.blackfire's
        # own "Add packagecloud apt key." task (url: only, no id:).
        fingerprints = key_fingerprints(tmp_path)
        if fingerprints.any? { |fp| key_present?(fp) }
          return PluginResult.new(changed: false, failed: false, msg: "Key already present")
        end

        result = remote_exec("apt-key #{keyring_flag}add #{tmp_path}")
        unless result[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true, msg: "apt-key add failed: #{result[:stderr]}")
        end
      ensure
        File.delete(tmp_path) rescue nil
      end

      PluginResult.new(changed: true, failed: false, msg: "Key added")
    end

    # Parses every key fingerprint out of the ASCII-armored/binary key
    # material at *path* without importing it into any keyring (`gpg
    # --import-options show-only` is a pure dry-run parse) - a key file
    # commonly bundles more than one key (a primary key plus one or more
    # subkeys), so this returns all of them; #add_key treats any one
    # already being present as the whole set already having been added.
    private def key_fingerprints(path : String) : Array(String)
      # A bare `gpg ...` with no `--homedir`/`--keyring` override touches
      # the SHARED default `~/.gnupg` - on a host with no prior `~/.gnupg`
      # at all, GnuPG 2.1+ auto-creates it (with an empty `pubring.kbx`,
      # KEYBOX format) as a side effect of ANY gpg invocation, even this
      # read-only `--import-options show-only` dry-run. Once that shared
      # homedir exists, a LATER `apt-key --keyring X add` (#add_key, right
      # after this call) apparently inherits its keybox backend preference
      # for the brand-new keyring file X too, instead of the classic
      # OpenPGP binary format apt's own `trusted.gpg.d` reader requires -
      # producing a keyring apt rejects outright ("the key(s) ... are
      # ignored as the file has an unsupported filetype"), silently
      # breaking every subsequent `apt-get update`/`apt-add-repository`
      # against that key. Real ansible.builtin.apt_key never calls bare
      # `gpg` at all (uses `apt-key --keyring X adv --list-public-keys`
      # for its own idempotency check instead - see its module source),
      # so it never touches the shared homedir in the first place. Fixed
      # here by giving this call its OWN throwaway `--homedir`, so it
      # can't poison `~/.gnupg` state that #add_key's later `apt-key add`
      # depends on staying untouched. Found benchmarking round167's
      # buluma.gitlab_ce on Ubuntu 22.04.
      tmp_home = "/tmp/.crystal-ansible-apt-key-gnupghome-#{Random.rand(100000..999999)}"
      result = remote_exec("mkdir -p #{tmp_home} && chmod 700 #{tmp_home} && gpg --homedir #{tmp_home} --with-colons --import-options show-only --import #{path} 2>/dev/null; rm -rf #{tmp_home}")
      result[:stdout].each_line.compact_map do |line|
        fields = line.split(':')
        fields[9] if fields[0]? == "fpr" && fields.size > 9 && !fields[9].empty?
      end.to_a
    end

    private def remove_key : PluginResult
      key_id = @params["id"]?
      return PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: id") unless key_id

      unless key_present?(key_id)
        return PluginResult.new(changed: false, failed: false, msg: "Key already absent")
      end

      result = remote_exec("apt-key #{keyring_flag}del #{key_id}")
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "apt-key del failed: #{result[:stderr]}")
      end

      PluginResult.new(changed: true, failed: false, msg: "Key removed")
    end

    private def key_present?(key_id : String) : Bool
      # `apt-key --keyring X list` against an X that does NOT exist yet
      # creates X as a side effect - an EMPTY file in GnuPG's modern
      # "keybox" format (not the classic OpenPGP binary format apt's own
      # `trusted.gpg.d` reader requires). On a keyring: task's very first
      # run (the common case - a fresh host, nothing installed yet), this
      # runs before #add_key's own `apt-key add` ever does, so THAT later
      # call finds X already exists (as an empty keybox) and appends the
      # imported key into it in keybox format too, instead of creating a
      # fresh classic-format file from scratch - apt then rejects the
      # whole keyring outright ("the key(s) ... are ignored as the file
      # has an unsupported filetype"), breaking every subsequent apt
      # operation that depended on it. Real ansible.builtin.apt_key hits
      # the same underlying `apt-key list`-creates-empty-keybox quirk in
      # principle, but never actually triggers it in this specific
      # ordering combination live-verified here. Since a keyring that
      # doesn't exist trivially can't contain the key, skip the `list`
      # call entirely (and its poisoning side effect) when the target
      # keyring: file isn't there yet. Found benchmarking round167's
      # buluma.gitlab_ce on Ubuntu 22.04.
      if keyring = @params["keyring"]?
        exists = remote_exec("test -e #{keyring}")
        return false if exists[:exit_code] != 0
      end

      # Real apt-key list output prints each key's fingerprint with
      # spaces every 4 characters - stripping spaces from both sides
      # before comparing so a shortened (e.g. last-8-hex-chars) id: still
      # matches inside the full fingerprint.
      result = remote_exec("apt-key #{keyring_flag}list 2>/dev/null")
      result[:stdout].gsub(" ", "").includes?(key_id.gsub(" ", ""))
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::AptKeyPlugin.new(config)
plugin.run
