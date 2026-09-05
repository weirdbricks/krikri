require "json"
require "uri"

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
