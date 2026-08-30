require "json"

module Krikri
  # Backing store for ansible.builtin.set_stats: - a single process-wide
  # accumulator (class-level, not per-TaskExecutor-instance) since
  # krikri-playbook.cr constructs a fresh TaskExecutor per play but the
  # custom-stats block real Ansible prints is for the WHOLE run, after
  # every play's PLAY RECAP.
  module CustomStats
    @@global = Hash(String, JSON::Any).new
    @@per_host = Hash(String, Hash(String, JSON::Any)).new

    def self.set(key : String, value : JSON::Any, aggregate : Bool, host_name : String?, per_host : Bool)
      if per_host && host_name
        bucket = (@@per_host[host_name] ||= Hash(String, JSON::Any).new)
        merge_into(bucket, key, value, aggregate)
      else
        merge_into(@@global, key, value, aggregate)
      end
    end

    def self.any? : Bool
      !@@global.empty? || !@@per_host.empty?
    end

    def self.empty? : Bool
      @@global.empty? && @@per_host.empty?
    end

    def self.global : Hash(String, JSON::Any)
      @@global
    end

    def self.per_host_data : Hash(String, Hash(String, JSON::Any))
      @@per_host
    end

    # Real Ansible's own aggregate: true (the default) sums a numeric
    # value into whatever's already stored under that key across
    # multiple set_stats: calls (e.g. a loop incrementing a counter);
    # any non-numeric value (or aggregate: false) just overwrites, same
    # as real Ansible.
    private def self.merge_into(bucket : Hash(String, JSON::Any), key : String, value : JSON::Any, aggregate : Bool)
      existing = bucket[key]?
      if aggregate && existing && numeric?(existing) && numeric?(value)
        if existing.raw.is_a?(Int64) && value.raw.is_a?(Int64)
          bucket[key] = JSON::Any.new(existing.as_i64 + value.as_i64)
        else
          bucket[key] = JSON::Any.new(existing.as_f + value.as_f)
        end
      else
        bucket[key] = value
      end
    end

    private def self.numeric?(v : JSON::Any) : Bool
      v.raw.is_a?(Int64) || v.raw.is_a?(Float64)
    end
  end
end
