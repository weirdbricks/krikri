require "json"
require "digest/sha256"
require "random/secure"
require "./bigint_json"
require "./param_sentinels"
require "./fact_cache_pickle"

module Krikri
  # Ansible's `fact_caching` support (`ANSIBLE_CACHE_PLUGIN`/
  # `ANSIBLE_CACHE_PLUGIN_CONNECTION` env vars - no ansible.cfg INI
  # parsing exists in this engine, matching the established pattern
  # elsewhere, e.g. ssh_manager.cr's own host_key_checking handling).
  # Two on-disk backends are implemented:
  #
  #   * `jsonfile` - the most common real-world choice.
  #   * `community.general.pickle` - matched so a cache directory written
  #     by ansible-playbook warms krikri (and vice versa), see
  #     fact_cache_pickle.cr for the format and its safety argument.
  #
  # The built-in default backend, `memory`, caches only within a single
  # process and needs no support here at all, since @facts already IS that
  # in-run cache; `redis`/`memcached` would need real client libraries this
  # project doesn't carry.
  #
  # Ansible's VariableManager merges the configured cache into every
  # host's vars on every play, gathering mode regardless: a play with
  # `gather_facts: false` still sees the cached facts from an earlier
  # run, and a re-gather merges fresh discovery over them (verified
  # live against ansible-core 2.21.6). Only SKIPPING the gather itself
  # is gated on `gathering: smart` - `implicit` (the default) and
  # `explicit` still re-run `setup.py` for a gathering play even with a
  # warm cache (verified against 2.19.12 and 2.21.6). The executor
  # therefore seeds @facts from this module for every play (see its
  # constructor) and writes back after any gather, while
  # `gathered_facts_for?` decides whether the gather can be skipped.
  module FactCache
    # Matches Ansible's `fact_caching_timeout` default (24h, in
    # seconds). `0` means never expire, same as Ansible.
    DEFAULT_TIMEOUT = 86400

    JSONFILE_BACKEND   = "jsonfile"
    PICKLE_BACKEND     = "community.general.pickle"
    SUPPORTED_BACKENDS = {JSONFILE_BACKEND, PICKLE_BACKEND}

    # Cache plugins whose required `_uri` config (the
    # fact_caching_connection) makes ansible-core warn at startup when
    # it is missing - live-verified vs 2.19.11 for both:
    #   [WARNING]: Required config '_uri' for 'jsonfile' cache plugin not provided.
    # The warning fires whenever the plugin is CONFIGURED without a
    # connection, even when no play gathers facts (the plugin load is
    # not gated on gathering), and a collection plugin renders fully
    # qualified (ansible_collections.<ns>.<collection>.plugins.cache.<name>).
    # Only these two are listed because they are the only plugins whose
    # _uri requirement this engine has verified; other backends would
    # need their own option specs to warn about correctly.
    URI_REQUIRED_PLUGINS = {"jsonfile", "community.general.pickle"}

    @@connection_warning_emitted = false

    # Test hook: forget that the warning was already emitted.
    def self.reset_connection_warning : Nil
      @@connection_warning_emitted = false
    end

    # Startup-time configuration warning, shared by both drivers (the
    # `ansible` ad-hoc binary warns the same way). Idempotent per
    # process. *io* injectable for specs.
    def self.warn_missing_connection(io : IO = STDERR) : Nil
      return if @@connection_warning_emitted
      @@connection_warning_emitted = true
      plugin = ENV["ANSIBLE_CACHE_PLUGIN"]?
      return unless plugin && URI_REQUIRED_PLUGINS.includes?(plugin)
      return unless (ENV["ANSIBLE_CACHE_PLUGIN_CONNECTION"]? || "").empty?
      display_name = plugin
      if plugin.split('.').size == 3
        ns, collection, name = plugin.split('.')
        display_name = "ansible_collections.#{ns}.#{collection}.plugins.cache.#{name}"
      end
      io.puts "[WARNING]: Required config '_uri' for '#{display_name}' cache plugin not provided."
    end

    def self.enabled? : Bool
      name = backend
      !name.nil? && SUPPORTED_BACKENDS.includes?(name) && !connection_dir.nil?
    end

    # Whether the configured backend stores Python pickles rather than
    # JSON text (the two share the `<host>` filename in a cache dir).
    private def self.pickle_backend? : Bool
      backend == PICKLE_BACKEND
    end

    private def self.backend : String?
      ENV["ANSIBLE_CACHE_PLUGIN"]?
    end

    private def self.connection_dir : String?
      dir = ENV["ANSIBLE_CACHE_PLUGIN_CONNECTION"]?
      return nil if dir.nil? || dir.empty?
      expanded = expand_connection(dir)
      # `~` with an empty HOME would otherwise resolve to "" and write the
      # cache into the process's working directory (ansible's own
      # validate_cache_connection treats an empty connection as unset).
      expanded.empty? ? nil : expanded
    end

    # Ansible's cache plugins run the connection through
    # `os.path.expanduser(os.path.expandvars(...))`, so `~/cache` and
    # `$HOME/cache` name the same directory for both engines. (`~user`, a
    # login-name lookup, is left alone - no fact-caching config uses it.)
    private def self.expand_connection(dir : String) : String
      expanded = dir.gsub(/\$\{(\w+)\}|\$(\w+)/) do
        name = $~[1]? || $~[2]?
        value = name ? ENV[name]? : nil
        # os.path.expandvars leaves a reference to an unset variable as-is.
        value || $~[0]
      end
      home = ENV["HOME"]?
      if home
        return home if expanded == "~"
        return File.join(home, expanded[2..]) if expanded.starts_with?("~/")
      end
      expanded
    end

    # Ansible's `fact_caching_prefix` (ANSIBLE_CACHE_PLUGIN_PREFIX): both
    # the jsonfile and pickle plugins prepend it verbatim to the cache key
    # when naming a file (`keys` skips entries not carrying it).
    private def self.file_prefix : String
      ENV["ANSIBLE_CACHE_PLUGIN_PREFIX"]? || ""
    end

    # A float: the pickle plugin's `_timeout` option is `type: float`, so
    # `ANSIBLE_CACHE_PLUGIN_TIMEOUT=0.5` is legal for ansible (it would
    # silently mean the 86400s default if parsed as an integer).
    private def self.timeout_seconds : Float64
      ENV["ANSIBLE_CACHE_PLUGIN_TIMEOUT"]?.try(&.to_f?) || DEFAULT_TIMEOUT.to_f64
    end

    # Ansible's BaseFileCacheModule uses the cache key (here, the
    # inventory host name) as the filename, replacing it with a sha256 of
    # the key when it carries anything path-ish. Matching that exactly is
    # what lets one cache directory serve both engines for such hosts.
    PATH_HAZARDS = ["/", "..", "<", ">", "|"]

    private def self.path_for(host_name : String) : String
      # callers gate on enabled?, which guarantees connection_dir - an
      # explicit nil-check instead of not_nil! (ameba Lint/NotNil)
      dir = connection_dir
      raise "fact cache path requested with no connection dir" unless dir
      # A host name from a dynamic inventory's hostvars keys / add_host:
      # carrying "/" or ".." would otherwise escape the cache dir and
      # write attacker-influenced data elsewhere - the same reasoning as
      # ansible's _sanitize_key, which this mirrors.
      safe = safe_key(host_name)
      safe = "_dot_" if safe.empty? || safe == "." || safe == ".."
      File.join(dir, "#{file_prefix}#{safe}")
    end

    private def self.safe_key(host_name : String) : String
      if PATH_HAZARDS.any? { |hazard| host_name.includes?(hazard) }
        Digest::SHA256.hexdigest(host_name)[0, {host_name.size, 12}.max]
      else
        host_name
      end
    end

    # Returns the cached facts for *host_name* if the cache is enabled,
    # a file exists, and it isn't older than the configured timeout -
    # nil otherwise (cache miss, expired, disabled, or unreadable).
    def self.read(host_name : String) : Hash(String, JSON::Any)?
      return nil unless enabled?
      path = path_for(host_name)
      return nil unless File.exists?(path)

      limit = timeout_seconds
      # ansible's has_expired: only exactly 0 disables expiry, and a
      # negative timeout therefore expires everything.
      unless limit == 0
        age = Time.utc - File.info(path).modification_time.to_utc
        return nil if age.total_seconds > limit
      end

      if pickle_backend?
        Pickle.decode(read_binary(path))
      else
        parsed = Krikri::BigJson.parse(File.read(path)).as_h?
        return nil unless parsed
        hash = Hash(String, JSON::Any).new
        parsed.each { |key, value| hash[key] = value }
        hash
      end
    rescue
      nil
    end

    private def self.read_binary(path : String) : Bytes
      size = File.size(path).to_i
      raise "cache file too large" if size > Pickle::MAX_BYTES
      bytes = Bytes.new(size)
      File.open(path, "rb") { |io| io.read_fully(bytes) }
      bytes
    end

    # Persists *facts* for *host_name*. Best-effort: a cache write
    # failure (unwritable connection dir, disk full, ...) must never
    # fail the play - Ansible's own fact-cache writes are equally
    # non-fatal.
    def self.write(host_name : String, facts : Hash(String, JSON::Any)) : Nil
      return unless enabled?
      dir = connection_dir
      return unless dir
      Dir.mkdir_p(dir) unless Dir.exists?(dir)
      path = path_for(host_name)
      # This run's facts were merged over whatever #read could return, so
      # replacing a pickle this codec cannot read would silently drop the
      # facts it could not parse (e.g. a construct a newer ansible-core
      # writes). Leave a real pickle alone and let the host re-gather.
      # Anything that is not a pickle at all (a jsonfile entry left behind
      # by switching backends, a stray file) is still replaced, so junk
      # cannot wedge the cache forever. Every Python protocol >= 2 stream
      # starts with the PROTO opcode, which is the cheapest way to tell
      # "another tool's pickle" from "not a pickle"; krikri writes
      # atomically, so it never leaves a truncated one of its own behind.
      return if pickle_backend? && unreadable_pickle?(path)
      if pickle_backend?
        bytes = Pickle.encode(facts)
        write_atomically(path) { |io| io.write(bytes) }
      else
        # A module-returned integer wider than Int64 rides the cached
        # facts as the BIGINT_SENTINEL_PREFIX-marked string; the cache
        # file stores its bare digits (the bytes Ansible's jsonfile
        # cache writes for a Python int) and the read side restores the
        # marker through the bigint-aware parse.
        payload = Krikri.unquote_bigint_json(facts.to_json)
        write_atomically(path) { |io| io.write(payload.to_slice) }
      end
    rescue
    end

    private def self.unreadable_pickle?(path : String) : Bool
      return false unless File.exists?(path)
      # Every Python protocol >= 2 stream starts with the PROTO opcode;
      # anything else (a jsonfile entry left behind by a backend switch, a
      # stray file) is junk and may be replaced.
      return false unless File.open(path, "rb") { |io| io.read_byte } == 0x80_u8
      Pickle.decode(read_binary(path))
      false
    rescue Pickle::Unsupported
      # A structurally valid pickle using a construct this codec does not
      # model: another engine's data, left untouched.
      true
    rescue
      # Not a cache-file pickle at all (truncated, non-mapping root,
      # invalid UTF-8): replacing it is safe and lets a bad entry heal.
      false
    end

    # Write to a sibling temp file, then rename over the target: a crash
    # mid-write leaves the previous entry intact instead of a truncated
    # file that the next run reads as a miss.
    private def self.write_atomically(path : String, & : IO ->) : Nil
      # A leading dot keeps a crash-orphaned temp file out of ansible's
      # cache `keys()` scan (it skips dotfiles), so neither engine ever
      # mistakes one for a host entry.
      tmp = File.join(File.dirname(path), ".#{File.basename(path)}.krikri-#{Process.pid}-#{Random::Secure.hex(4)}.tmp")
      begin
        # Cached facts frequently embed ansible_env (the controller's
        # whole environment - API tokens included) and set_fact-ed
        # secrets: store them owner-only rather than umask-default 0644.
        File.open(tmp, "wb") do |io|
          io.chmod(0o600)
          yield io
        end
        File.rename(tmp, path)
      ensure
        File.delete(tmp) if File.exists?(tmp)
      end
    end

    # Drops the persisted facts for *host_name* - what `meta:
    # clear_facts` does to the cache in Ansible (its clear_facts calls
    # the plugin's delete, which unlinks the jsonfile entry). Without
    # this the next play's seeding would resurrect facts the run was
    # told to forget. Best-effort, like #write.
    def self.delete(host_name : String) : Nil
      return unless enabled?
      path = path_for(host_name)
      File.delete(path) if File.exists?(path)
    rescue
    end
  end
end
