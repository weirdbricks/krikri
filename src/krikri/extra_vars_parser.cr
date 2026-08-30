require "json"
require "yaml"

module Krikri
  # `-e` / `--extra-vars`, real Ansible's highest-precedence variable
  # scope. Every accepted form below was checked against a real
  # ansible-core 2.19.4 before being implemented here:
  #
  #   -e key=value            one or more whitespace-separated k=v pairs;
  #                           the value is ALWAYS a string, so
  #                           `-e num=5` yields "5" (type_debug: str),
  #                           not the integer 5
  #   -e '{"k": 1}'          a JSON object - real types preserved, so
  #                           num stays an int here
  #   -e @vars.yml            load a YAML (or JSON) file
  #   repeated -e             later occurrences win on a key collision
  #
  # Precedence relative to everything else is handled by the executor,
  # which applies the parsed result last - see TaskExecutor's @extra_vars.
  module ExtraVarsParser
    class Error < Exception
    end

    # Parses CLI occurrences in order, merging later over earlier.
    def self.parse(occurrences : Array(String)) : Hash(String, JSON::Any)
      merged = {} of String => JSON::Any
      occurrences.each do |raw|
        parse_one(raw).each { |key, value| merged[key] = value }
      end
      merged
    end

    private def self.parse_one(raw : String) : Hash(String, JSON::Any)
      value = raw.strip
      raise Error.new("--extra-vars given an empty value") if value.empty?

      case value[0]
      when '@'      then from_file(value[1..])
      when '{', '[' then from_structured(value)
      else               from_pairs(value)
      end
    end

    private def self.from_file(path : String) : Hash(String, JSON::Any)
      raise Error.new("extra-vars file not found: #{path}") unless File.exists?(path)

      from_structured(File.read(path), source: path)
    end

    # JSON and YAML both, because real Ansible accepts either for an
    # inline value and for an @file - and JSON is a subset of YAML, so
    # one parser covers both. Parsed via YAML::Any then re-encoded to
    # JSON::Any, the representation the rest of the engine uses.
    private def self.from_structured(text : String, source : String? = nil) : Hash(String, JSON::Any)
      parsed = begin
        YAML.parse(text)
      rescue ex
        raise Error.new("could not parse extra-vars#{source ? " from #{source}" : ""}: #{ex.message}")
      end

      hash = parsed.as_h?
      unless hash
        raise Error.new("extra-vars#{source ? " from #{source}" : ""} must be a mapping of names to values, not a #{parsed.raw.class}")
      end

      result = {} of String => JSON::Any
      hash.each do |key, value|
        result[key.to_s] = JSON.parse(value.to_json)
      end
      result
    end

    # `-e "k1=v1 k2=v2"` - whitespace-separated pairs, values always
    # strings. A value may itself contain '=' (`-e url=a=b`), so only the
    # FIRST '=' separates.
    private def self.from_pairs(text : String) : Hash(String, JSON::Any)
      result = {} of String => JSON::Any
      text.split(/\s+/).reject(&.empty?).each do |pair|
        separator = pair.index('=')
        unless separator && separator > 0
          raise Error.new("extra-vars must be key=value, JSON, or @file - got #{pair.inspect}")
        end

        result[pair[0...separator]] = JSON::Any.new(pair[(separator + 1)..])
      end
      result
    end
  end
end
