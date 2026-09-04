require "json"

module Krikri
  # Real Ansible's `fact_caching` support (`ANSIBLE_CACHE_PLUGIN`/
  # `ANSIBLE_CACHE_PLUGIN_CONNECTION` env vars - no ansible.cfg INI
  # parsing exists in this engine, matching the established pattern
  # elsewhere, e.g. ssh_manager.cr's own host_key_checking handling).
  # Only the `jsonfile` backend is implemented - by far the most common
  # real-world choice (the built-in default backend, `memory`, caches
  # only within a single process and needs no support here at all,
  # since @facts already IS that in-run cache; `redis`/`memcached`
  # would need real client libraries this project doesn't carry).
  #
  # Real Ansible only ever CONSULTS the cache under `gathering: smart`
  # (or explicit + a play that skips gather_facts:) - `gathering:
  # implicit` (the default) always re-gathers regardless of a
  # configured cache, verified live against ansible-core 2.19.12: a
  # warm fact-cache with default implicit gathering still re-ran
  # `setup.py` every play. So this module is only ever consulted from
  # the executor's existing `@smart_gathering` path (see
  # `gather_facts_for_all_hosts`), never for implicit/explicit
  # gathering - that mirrors real Ansible's own gating rather than
  # reintroducing a second, independent on/off switch.
  module FactCache
    # Matches real Ansible's `fact_caching_timeout` default (24h, in
    # seconds). `0` means never expire, same as real Ansible.
    DEFAULT_TIMEOUT = 86400

    def self.enabled? : Bool
      backend == "jsonfile" && !connection_dir.nil?
    end

    private def self.backend : String?
      ENV["ANSIBLE_CACHE_PLUGIN"]?
    end

    private def self.connection_dir : String?
      dir = ENV["ANSIBLE_CACHE_PLUGIN_CONNECTION"]?
      dir && !dir.empty? ? dir : nil
    end

    private def self.timeout_seconds : Int32
      ENV["ANSIBLE_CACHE_PLUGIN_TIMEOUT"]?.try(&.to_i?) || DEFAULT_TIMEOUT
    end

    # Real Ansible's jsonfile cache plugin uses the cache key (here,
    # the inventory host name) directly as the filename - no hashing or
    # sanitization beyond what the filesystem itself enforces.
    private def self.path_for(host_name : String) : String
      # callers gate on enabled?, which guarantees connection_dir - an
      # explicit nil-check instead of not_nil! (ameba Lint/NotNil)
      dir = connection_dir
      raise "fact cache path requested with no connection dir" unless dir
      File.join(dir, host_name)
    end

    # Returns the cached facts for *host_name* if the cache is enabled,
    # a file exists, and it isn't older than the configured timeout -
    # nil otherwise (cache miss, expired, disabled, or unreadable).
    def self.read(host_name : String) : Hash(String, JSON::Any)?
      return nil unless enabled?
      path = path_for(host_name)
      return nil unless File.exists?(path)

      limit = timeout_seconds
      if limit > 0
        age = Time.utc - File.info(path).modification_time.to_utc
        return nil if age.total_seconds > limit
      end

      parsed = JSON.parse(File.read(path)).as_h?
      return nil unless parsed
      hash = Hash(String, JSON::Any).new
      parsed.each { |key, value| hash[key] = value }
      hash
    rescue
      nil
    end

    # Persists *facts* for *host_name*. Best-effort: a cache write
    # failure (unwritable connection dir, disk full, ...) must never
    # fail the play - real Ansible's own fact-cache writes are equally
    # non-fatal.
    def self.write(host_name : String, facts : Hash(String, JSON::Any)) : Nil
      return unless enabled?
      dir = connection_dir
      return unless dir
      Dir.mkdir_p(dir) unless Dir.exists?(dir)
      File.write(path_for(host_name), facts.to_json)
    rescue
    end
  end
end
