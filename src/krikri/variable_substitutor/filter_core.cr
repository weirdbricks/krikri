require "json"
require "uri"
require "openssl/digest"
require "uuid"
require "yaml"
require "base64"

module Krikri
  module VariableSubstitutor
    # Shared pure implementations for the string/path/filter family that
    # used to exist as TWO independently-maintained copies - one on
    # Crinja::Value (jinja_filters.cr, the `{%`/`{#` block-tag evaluator)
    # and one on JSON::Any (variable_substitutor/filter_engine.cr, the
    # hand-rolled `{{ }}` evaluator). Same drift class this project has
    # hit repeatedly (rerender_if_templated, shell_single_quote,
    # normalize_path/common_path were already byte-identical twins here).
    #
    # Functions are pure and take plain Crystal types; each evaluator's
    # filter registration converts its own value/argument representation
    # to these and wraps the result. NOT a full merge of the two
    # evaluators (see CLAUDE.md's two-evaluators note) - only the
    # filter-logic cores that were already algorithmically identical.
    module FilterCore
      # The process-wide compiled-regex cache lives HERE now (FilterCore
      # is the bottom of the dependency graph - both evaluators require
      # it, so it must not itself depend on FilterEngine);
      # FilterEngine.cached_regex delegates to this.
      @@compiled_regex_cache = Hash(Tuple(String, Regex::Options), Regex).new

      def self.cached_regex(pattern : String, options : Regex::Options = Regex::Options::None) : Regex
        key = {pattern, options}
        @@compiled_regex_cache[key] ||= Regex.new(pattern, options)
      end

      # regex_replace(pattern, replacement='') - Python re.sub semantics:
      # every match replaced, `\1`-style backreferences in *replacement*
      # substituted from the matched capture groups (a non-participating
      # group renders as empty). This is the hand-rolled evaluator's
      # implementation - the Crinja copy used Crystal's native
      # gsub(pattern, replacement) backref expansion, which differs in
      # corner cases (missing-group and multi-digit handling); one
      # implementation now, so both evaluators answer identically.
      def self.regex_replace(s : String, pattern : String, replacement : String) : String
        s.gsub(cached_regex(pattern)) do |_, mat|
          replacement.gsub(/\\(\d)/) { mat[$1.to_i]? || "" }
        end
      end

      # regex_escape(re_type='python') - escapes regex special characters
      # so the value can be embedded literally into a larger pattern.
      def self.regex_escape(s : String) : String
        Regex.escape(s)
      end

      # urldecode() - percent-decodes a URL-encoded string.
      def self.urldecode(s : String) : String
        URI.decode(s)
      end

      # normpath() - mirrors Python's os.path.normpath: collapses
      # `.`/`..`/redundant `/` without making the path absolute
      # (relative stays relative).
      def self.normpath(path : String) : String
        return "." if path.empty?
        absolute = path.starts_with?('/')
        parts = path.split('/').reject { |pth| pth.empty? || pth == "." }

        result = [] of String
        parts.each do |part|
          merge_norm_part(result, part, absolute)
        end

        joined = result.join("/")
        absolute ? "/#{joined}" : (joined.empty? ? "." : joined)
      end

      # One os.path.normpath step for *part* against the accumulated
      # *result*: a `..` pops one accumulated segment, is KEPT as a
      # leading `..` on a relative path, or is dropped entirely at the
      # root of an absolute path; anything else appends.
      private def self.merge_norm_part(result : Array(String), part : String, absolute : Bool) : Nil
        if part == ".."
          if !result.empty? && result.last != ".."
            result.pop
          elsif !absolute
            result << part
          end
        else
          result << part
        end
      end

      def self.basename(s : String) : String
        File.basename(s)
      end

      def self.dirname(s : String) : String
        File.dirname(s)
      end

      # splitext() - mirrors Python's os.path.splitext: {root, ext} with
      # ext including the leading '.' (empty string if no extension).
      def self.splitext(s : String) : {String, String}
        ext = File.extname(s)
        root = ext.empty? ? s : s[0, s.size - ext.size]
        {root, ext}
      end

      # commonpath() - mirrors Python's os.path.commonpath: the longest
      # shared leading sequence of path SEGMENTS (not a naive character
      # prefix) across every path in *paths*.
      def self.commonpath(paths : Array(String)) : String
        return "" if paths.empty?
        segments = paths.map { |pth| pth.split('/').reject(&.empty?) }
        first = segments.first
        common = first.each_with_index.take_while { |seg, i| segments.all? { |str| str[i]? == seg } }.map(&.[0])
        prefix = paths.first.starts_with?('/') ? "/" : ""
        "#{prefix}#{common.join("/")}"
      end

      # path_join(list) - joins path components with os.path.join
      # semantics (an absolute component resets the accumulated path
      # rather than appending to it - Crystal's own File.join has no
      # such reset).
      def self.path_join(parts : Array(String)) : String
        parts.reduce("") { |acc, part| part.starts_with?('/') ? part : File.join(acc, part) }
      end

      # expanduser() - a leading `~` (or `~user`, not supported - only
      # the current-user shorthand) expands to $HOME.
      def self.expanduser(s : String) : String
        home = ENV["HOME"]? || ""
        s.starts_with?("~/") ? File.join(home, s[2..]) : (s == "~" ? home : s)
      end

      # expandvars() - `$VAR`/`${VAR}` references replaced from the
      # CONTROLLER's own environment (unset -> left as-is, matching
      # Python's own behavior).
      def self.expandvars(s : String) : String
        s.gsub(/\$\{(\w+)\}|\$(\w+)/) do |match|
          name = $1? || $2?
          name ? (ENV[name]? || match) : match
        end
      end

      # hash(algorithm='sha1') - wraps Python's hashlib.new(). Defaults
      # to sha1; raises on unsupported algorithms (real Ansible does too).
      def self.hash(s : String, algorithm : String) : String
        openssl_name = case algorithm.downcase
                       when "md5"    then "MD5"
                       when "sha1"   then "SHA1"
                       when "sha224" then "SHA224"
                       when "sha256" then "SHA256"
                       when "sha384" then "SHA384"
                       when "sha512" then "SHA512"
                       else
                         raise "hash: unsupported algorithm '#{algorithm}'"
                       end
        digest(s, openssl_name)
      end

      # checksum() - always sha1 (Ansible's own hard-coded
      # hashlib.sha1), distinct from the general-purpose hash filter.
      def self.checksum(s : String) : String
        digest(s, "SHA1")
      end

      def self.md5(s : String) : String
        digest(s, "MD5")
      end

      def self.sha1(s : String) : String
        digest(s, "SHA1")
      end

      private def self.digest(s : String, openssl_name : String) : String
        d = OpenSSL::Digest.new(openssl_name)
        d.update(s)
        d.final.hexstring
      end

      # password_hash(hashtype='sha512', salt=None, rounds=None) - a
      # salted crypt(3) hash suitable for /etc/shadow (NOT a plain
      # digest). Covers the three crypt(3) schemes `openssl passwd`
      # supports (sha512/sha256/md5 = $6$/$5$/$1$); passlib-only schemes
      # like bcrypt aren't available without a real passlib port.
      def self.password_hash(s : String, hashtype : String, salt : String? = nil) : String
        openssl_flag = case hashtype.downcase
                       when "md5"    then "-1"
                       when "sha256" then "-5"
                       when "sha512" then "-6"
                       else
                         raise "password_hash: unsupported hashtype '#{hashtype}' (supported: md5, sha256, sha512)"
                       end
        salt = salt.presence || Random::Secure.hex(8)

        output = IO::Memory.new
        status = Process.run("openssl", ["passwd", openssl_flag, "-salt", salt, "-stdin"],
          input: IO::Memory.new(s), output: output)
        raise "password_hash: openssl passwd failed" unless status.success?
        output.to_s.strip
      end

      # to_uuid(namespace=ANSIBLE_NAMESPACE) - deterministic UUID5
      # (SHA1-based) using Ansible's own default namespace.
      def self.to_uuid(s : String) : String
        UUID.v5(s, UUID.new("361E6D51-FAEC-444A-9079-341386DA8E2E")).to_s
      end

      # b64encode/b64decode - standard base64 (not urlsafe). b64decode
      # raises on invalid input (real Ansible does too).
      def self.b64encode(s : String) : String
        Base64.strict_encode(s)
      end

      def self.b64decode(s : String) : String
        Base64.decode_string(s)
      rescue
        raise "b64decode: invalid base64 input"
      end

      # from_json() - parses a JSON string into a real structure;
      # raises on invalid input (real Ansible does too).
      def self.from_json(s : String) : JSON::Any
        JSON.parse(s)
      rescue
        raise "from_json: invalid JSON input"
      end

      # from_yaml() - real Ansible only calls yaml.safe_load when the
      # input IS a string; any other type returns as-is unchanged (the
      # non-string passthrough here is REAL behavior, verified live -
      # the stringify-then-parse shape used to fail whole templates on
      # already-structured input).
      def self.from_yaml(value : JSON::Any) : JSON::Any
        return value unless value.raw.is_a?(String)
        JSON.parse(YAML.parse(value.raw.as(String)).to_json)
      rescue
        raise "from_yaml: invalid YAML input"
      end

      # to_json(**kwargs) - Python json.dumps() shape: default ", "/
      # ": " item/key separators, not Crystal's compact JSON::Builder.
      def self.to_json(value : JSON::Any) : String
        String.build { |io| python_json_dump(value, io) }
      end

      def self.python_json_dump(value : JSON::Any, io : IO) : Nil
        case raw = value.raw
        when Nil
          io << "null"
        when Bool
          io << raw
        when String
          raw.to_json(io)
        when Int64, Int32, Float64
          io << raw
        when Array
          io << '['
          raw.each_with_index do |item, index|
            io << ", " if index > 0
            python_json_dump(item, io)
          end
          io << ']'
        when Hash
          io << '{'
          first = true
          raw.each do |key, item|
            io << ", " unless first
            first = false
            key.to_s.to_json(io)
            io << ": "
            python_json_dump(item, io)
          end
          io << '}'
        else
          raw.to_s.to_json(io)
        end
      end

      # to_nice_json(indent=4, sort_keys=True) - a pretty-printed JSON
      # dump. Crystal's own JSON::Any#to_pretty_json (2-space indent) is
      # used rather than hand-rolling a 4-space emitter - narrower than
      # real Ansible's exact byte output but structurally correct.
      def self.to_nice_json(value : JSON::Any, sort_keys : Bool = true) : String
        sorted = sort_keys ? sort_json_keys(value) : value
        sorted.to_pretty_json
      end

      # to_yaml() - a YAML dump (real PyYAML default: block style, keys
      # sorted). Converts via value.to_json -> YAML.parse -> to_yaml
      # (JSON is a valid YAML flow-syntax subset, round-trips cleanly
      # through Crystal's own YAML formatter), strips the leading
      # document marker PyYAML's own output never has.
      def self.to_yaml(value : JSON::Any) : String
        YAML.parse(sort_json_keys(value).to_json).to_yaml.sub(/\A---[ \t]*\n?/, "").rstrip
      end

      # Recursively sorts dict keys - used by to_nice_json/to_yaml
      # (real Ansible's sort_keys=True defaults).
      def self.sort_json_keys(value : JSON::Any) : JSON::Any
        case raw = value.raw
        when Hash
          sorted = raw.to_a.sort_by { |(k, _)| k }
          JSON::Any.new(sorted.to_h { |(k, v)| {k, sort_json_keys(v)} })
        when Array
          JSON::Any.new(raw.map { |v| sort_json_keys(v) })
        else
          value
        end
      end

      # Set operations over JSON arrays - real Ansible's own filters,
      # set semantics preserving first-seen order and deduplicating
      # within each source list (Ansible's own `_unique_dedupe` approach,
      # not naive concatenation). Equality is by canonical JSON form so
      # nested dicts/arrays compare structurally.
      def self.union(a : Array(JSON::Any), b : Array(JSON::Any)) : Array(JSON::Any)
        (a + b).uniq(&.to_json)
      end

      def self.intersect(a : Array(JSON::Any), b : Array(JSON::Any)) : Array(JSON::Any)
        bset = b.to_set
        a.uniq.select { |item| bset.includes?(item) }
      end

      def self.difference(a : Array(JSON::Any), b : Array(JSON::Any)) : Array(JSON::Any)
        bset = b.to_set
        a.uniq.reject { |item| bset.includes?(item) }
      end

      def self.symmetric_difference(a : Array(JSON::Any), b : Array(JSON::Any)) : Array(JSON::Any)
        left = a.uniq(&.to_json)
        right = b.uniq(&.to_json)
        left_json = left.map(&.to_json).to_set
        right_json = right.map(&.to_json).to_set
        (left.reject { |i| right_json.includes?(i.to_json) } +
          right.reject { |i| left_json.includes?(i.to_json) })
      end

      # type_debug - Python's type name for the value (matching
      # `type(x).__name__`), used almost exclusively in role assert.yml
      # sanity checks (`my_list | type_debug == "list"`).
      def self.type_debug(value : JSON::Any) : String
        case value.raw
        when Array   then "list"
        when Hash    then "dict"
        when String  then "str"
        when Int64   then "int"
        when Float64 then "float"
        when Bool    then "bool"
        when Nil     then "NoneType"
        else              "str"
        end
      end
    end
  end
end
