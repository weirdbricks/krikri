#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
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
  #
  # - post-add verification: `apt-key add` can exit 0 WITHOUT the key
  #   actually landing in the listed keyring - the real acandid.jenkins
  #   role (round 83166) ships an EXPIRED signing key (its
  #   pkg.jenkins.io/debian/jenkins.io.key expired 2023-03-30); the add
  #   prints "OK" and exits 0, the key genuinely is in
  #   /etc/apt/trusted.gpg, but `apt-key adv --list-public-keys` output
  #   marks it expired and real ansible.builtin.apt_key's own key
  #   parser (`parse_output_for_keys`) deliberately SKIPS pub/sub lines
  #   containing "expired" - so its post-add re-list doesn't see the
  #   key and it fails the task with "apt-key did not return an error,
  #   but failed to add the key (check that the id is correct and *not*
  #   a subkey)" (verified live against real ansible-playbook on the
  #   round-83166 host: before == after, task failed). Previously the
  #   add path trusted apt-key's exit code alone and reported success -
  #   diverging both in the task result and in what ran next (real
  #   Ansible stops at the failed apt_key: task; krikri continued into
  #   apt_repository: and failed later with a NO_PUBKEY apt-get update
  #   error instead). Fixed by mirroring real Ansible's whole add flow:
  #   derive the key id from the staged material via `gpg --with-colons`
  #   when id: isn't given (same as its get_key_id_from_file, first
  #   parsed key wins), normalize it the way its parse_key_id does
  #   (uppercase, optional 0x, last-16-chars fingerprint), list existing
  #   keys the way its all_keys does (`apt-key adv --list-public-keys
  #   --keyid-format=long`, expired lines filtered), and re-list +
  #   verify after every add (url:/data:/file:/keyserver:) with its
  #   exact failure message.
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
      keyring ? "--keyring #{shell_single_quote(keyring)} " : ""
    end

    private def add_key : PluginResult
      url = @params["url"]?
      data = @params["data"]?
      file_path = @params["file"]?

      key_id = @params["id"]?
      key_id = nil if key_id.try(&.empty?)

      # Real Ansible's exact check order: `if not key_id: if keyserver:
      # fail "Missing key_id, required with keyserver."` happens before
      # any url:/data:/file: handling.
      keyserver = @params["keyserver"]?
      if key_id.nil? && keyserver
        return PluginResult.new(changed: false, failed: true, msg: "Missing key_id, required with keyserver.")
      end

      # keyserver: needs no key material at all (real Ansible's add path
      # is `apt-key adv --keyserver ... --recv <id>`), so the url/data/
      # file requirement below only applies to the material-based paths.
      unless url || data || file_path || keyserver
        return PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: url or data")
      end

      tmp_path = "/tmp/.krikri-playbook-apt-key-#{Random.rand(100000..999999)}"
      staged = false
      added = false
      begin
        if key_id.nil?
          # No id: given - real Ansible derives it from the key material
          # itself (get_key_id_from_file, first parsed key wins), which
          # is also what makes its idempotency + post-add verification
          # work for the common url:-only shape.
          staged_result = stage_key_material(url, data, file_path, tmp_path)
          return staged_result if staged_result
          staged = true

          derived = get_key_id_from_file(tmp_path)
          return PluginResult.new(changed: false, failed: true, msg: "Unable to extract key from #{tmp_path}") if derived[:exit_code] != 0
          return PluginResult.new(changed: false, failed: true, msg: "Invalid key_id") unless derived_key = derived[:key_id]
          key_id = derived_key
        end

        parsed = parse_key_id(key_id)
        return PluginResult.new(changed: false, failed: true, msg: "Invalid key_id") unless parsed

        before_keys = all_keys
        return PluginResult.new(changed: false, failed: true, msg: "Unable to list public keys") unless before_keys

        unless key_id_in_keys?(parsed, before_keys)
          if keyserver
            result = remote_exec("apt-key #{keyring_flag}adv --no-tty --keyserver #{shell_single_quote(keyserver)} --recv #{shell_single_quote(parsed[:key_id])}")
            unless result[:exit_code] == 0
              return PluginResult.new(changed: false, failed: true, msg: "Error fetching key #{key_id} from keyserver: #{result[:stderr]}")
            end
          else
            unless staged
              staged_result = stage_key_material(url, data, file_path, tmp_path)
              return staged_result if staged_result
            end

            result = remote_exec("apt-key #{keyring_flag}add #{tmp_path}")
            unless result[:exit_code] == 0
              return PluginResult.new(changed: false, failed: true, msg: "apt-key add failed: #{result[:stderr]}")
            end
          end

          # Verify it actually landed - apt-key add exits 0 even when the
          # key doesn't show up in the listing (see the class doc's
          # expired-key discussion for the real acandid.jenkins case).
          after_keys = all_keys
          return PluginResult.new(changed: true, failed: true, msg: "Unable to list public keys") unless after_keys

          unless key_id_in_keys?(parsed, after_keys)
            return PluginResult.new(changed: true, failed: true, msg: "apt-key did not return an error, but failed to add the key (check that the id is correct and *not* a subkey)")
          end

          added = true
        end
      ensure
        File.delete(tmp_path) rescue nil
      end

      PluginResult.new(changed: added, failed: false, msg: added ? "Key added" : "Key already present")
    end

    # Stage the key material (from url:/data:/file:) into tmp_path.
    # Returns the failure result when fetching/reading fails, nil on
    # success.
    private def stage_key_material(url : String?, data : String?, file_path : String?, tmp_path : String) : PluginResult?
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
        insecure_flag = true?(@params["validate_certs"]?, default: true) ? "" : "--insecure "
        result = remote_exec("curl --fail --silent --show-error --location #{insecure_flag}-o #{tmp_path} #{shell_single_quote(url)}")
        unless result[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true, msg: "Failed to fetch key from #{url}: #{result[:stderr]}")
        end
      elsif d = data
        File.write(tmp_path, d)
      else
        # file: is a path on the TARGET (real Ansible's own apt_key:file:
        # semantics - mrlesmithjr.ansible_es_apm_server copies the key to
        # /tmp first, then points file: at that path). Stage it into the
        # same tmp the data:/url: branches use so the rest of the import
        # path is unchanged. remote_exec's cwd is the target's root, and
        # a plain cp keeps us from re-reading the file through Crystal.
        result = remote_exec("cp #{shell_single_quote(file_path || raise "apt_key: file: path is required")} #{tmp_path}")
        unless result[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true, msg: "Failed to read key file #{file_path}: #{result[:stderr]}")
        end
      end

      nil
    end

    # Extracts the first key id from the ASCII-armored/binary key
    # material at *path* WITHOUT importing it into any keyring, the way
    # real ansible.builtin.apt_key's get_key_id_from_file does:
    # `gpg --with-colons <file>`, then parse_output_for_keys on the
    # output (its "assume we only want first key?" comment). The
    # throwaway --homedir isolation matters as much as the parse - see
    # the comment above it.
    private def get_key_id_from_file(path : String) : NamedTuple(exit_code: Int32, key_id: String?)
      # A bare `gpg ...` with no `--homedir`/`--keyring` override touches
      # the SHARED default `~/.gnupg` - on a host with no prior `~/.gnupg`
      # at all, GnuPG 2.1+ auto-creates it (with an empty `pubring.kbx`,
      # KEYBOX format) as a side effect of ANY gpg invocation, even this
      # read-only parse. Once that shared homedir exists, a LATER
      # `apt-key --keyring X add` (#add_key, right after this call)
      # apparently inherits its keybox backend preference for the
      # brand-new keyring file X too, instead of the classic OpenPGP
      # binary format apt's own `trusted.gpg.d` reader requires -
      # producing a keyring apt rejects outright ("the key(s) ... are
      # ignored as the file has an unsupported filetype"), silently
      # breaking every subsequent `apt-get update`/`apt-add-repository`
      # against that key. Found benchmarking round167's buluma.gitlab_ce
      # on Ubuntu 22.04, so this parse gets its OWN throwaway `--homedir`
      # it can't poison shared state through. (`rm -rf` runs before
      # `exit`, so the shell's exit status is gpg's own.)
      tmp_home = "/tmp/.krikri-playbook-apt-key-gnupghome-#{Random.rand(100000..999999)}"
      result = remote_exec("mkdir -p #{tmp_home} && chmod 700 #{tmp_home} && gpg --homedir #{tmp_home} --with-colons #{path} 2>/dev/null; gpg_rc=$?; rm -rf #{tmp_home}; exit $gpg_rc")
      keys = parse_output_for_keys(result[:stdout])
      {exit_code: result[:exit_code], key_id: keys.first?}
    end

    # Real ansible.builtin.apt_key's parse_output_for_keys, mirrored:
    # collects key ids out of both `apt-key adv --list-public-keys`
    # output (apt's own `pub   rsa4096/<ID> ...` format, code after the
    # slash) and plain `gpg --with-colons` output (field 4), skipping
    # every pub/sub line that mentions "expired" - deliberately, so an
    # expired key never counts as installed (which is exactly why real
    # Ansible's post-add verification fails for one, see the class doc).
    private def parse_output_for_keys(output : String) : Array(String)
      found = [] of String
      output.each_line do |line|
        next unless line.starts_with?("pub") || line.starts_with?("sub")
        next if line.includes?("expired")

        tokens = line.split
        code = tokens[1]?
        if code && (slash = code.index('/'))
          found << code[(slash + 1)..]
        else
          fields = line.split(':')
          found << fields[4] if fields.size > 4 && !fields[4].empty?
        end
      end
      found
    end

    # Real ansible.builtin.apt_key's parse_key_id, mirrored: uppercase,
    # optional 0x prefix, must be 8, 16, or 16+ hex chars; the id apt-key
    # subcommands take is the whole thing, the id its keyring listings
    # can be compared against is the LAST 16 chars (fingerprint), and an
    # 8-char id switches the whole module to short-format matching.
    # Returns nil when real Ansible would raise ValueError (its caller
    # fails with "Invalid key_id").
    private def parse_key_id(raw : String) : NamedTuple(key_id: String, fingerprint: String, short_key_id: String, short_format: Bool)?
      key_id = raw.upcase
      key_id = key_id[2..] if key_id.starts_with?("0X")
      return nil if key_id.empty? || !key_id.matches?(/\A[0-9A-F]+\z/)
      return nil unless key_id.size == 8 || key_id.size >= 16

      {
        key_id:       key_id,
        fingerprint:  key_id.size > 16 ? key_id[-16..] : key_id,
        short_key_id: key_id[-8..],
        short_format: key_id.size == 8,
      }
    end

    # Real ansible.builtin.apt_key's all_keys, mirrored: every key id in
    # the effective keyring, via `apt-key adv --list-public-keys
    # --keyid-format=long` + parse_output_for_keys. Returns nil when the
    # listing itself fails (real Ansible fails the task with "Unable to
    # list public keys"). Returns an empty list without touching apt-key
    # at all when a keyring: file doesn't exist yet - see the comment in
    # #key_present? for the empty-keybox side effect being avoided.
    private def all_keys : Array(String)?
      if keyring = @params["keyring"]?
        exists = remote_exec("test -e #{keyring}")
        return [] of String if exists[:exit_code] != 0
      end

      result = remote_exec("apt-key #{keyring_flag}adv --list-public-keys --keyid-format=long 2>/dev/null")
      return nil if result[:exit_code] != 0

      parse_output_for_keys(result[:stdout])
    end

    private def key_id_in_keys?(parsed : NamedTuple(key_id: String, fingerprint: String, short_key_id: String, short_format: Bool), keys : Array(String)) : Bool
      keys.includes?(parsed[:short_format] ? parsed[:short_key_id] : parsed[:fingerprint])
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
plugin = Krikri::AptKeyPlugin.new(config)
plugin.run
