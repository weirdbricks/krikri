require "yaml"

module Krikri
  # Registry of UNSAFE TEXTS - strings that are verbatim content, never
  # template text, wherever they surface. Two sources feed it:
  #
  # - YAML `!unsafe`-tagged scalars (real Ansible's `!unsafe` tag: "this
  #   value is never templated"). Parsed YAML loses tag information by
  #   the time it becomes JSON::Any, so each YAML var source (playbook,
  #   role defaults/vars, vars_files, include_vars, inventory host/group
  #   vars, extra-vars) pre-scans its raw text with #mark_yaml_text
  #   before parsing, and every scalar carrying the `!unsafe` tag is
  #   recorded here by its exact text.
  # - execution results: every string inside a `register:`ed module
  #   result, a `set_fact:` write, or a gathered fact that contains Jinja
  #   markers is recorded (TaskExecutor#build_vars_context walks the
  #   per-host stores once per task before publishing the unsafe-name
  #   registry). This is the value-level complement to the name registry:
  #   the name gate stops a DIRECT reference (`{{ r.stdout }}`) from
  #   re-rendering, while the text set also stops the same hostile text
  #   after it flowed through an author-defined template or a set_fact
  #   copy - real ansible-core's taint follows the data, and a hostile
  #   target must not get controller code execution by returning stdout
  #   shaped like `{{ lookup('pipe', ...) }}` no matter how many author
  #   templates relay it.
  #
  # The re-render gates consult #unsafe_text? alongside the per-host
  # unsafe-name registry: a value whose exact text is registered here is
  # passed through verbatim on every evaluation path.
  #
  # Exact-match only: real Ansible's taint would also follow DERIVED
  # strings (`"x" + unsafe_var`, a `| trim` of hostile text), but
  # matching by exact text keeps the gate O(1) per re-render decision.
  # Derived-string taint beyond what the span gate's own resolved-value
  # scan covers is a documented residual gap.
  module UnsafeValues
    @@texts = Set(String).new

    # Scans *text* (a YAML document about to be parsed) for `!unsafe`
    # -tagged scalars and records their values. Cheap when the document
    # contains no tag at all; a malformed document must never fail the
    # real parse that follows, so any pull-parser error is swallowed.
    def self.mark_yaml_text(text : String) : Nil
      return unless text.includes?("!unsafe")
      begin
        YAML::PullParser.new(text) do |parser|
          parser.read_stream do
            parser.read_document do
              walk(parser)
            end
          end
        end
      rescue YAML::ParseException
        nil
      end
    end

    # Whether *raw* is the exact text of a `!unsafe`-tagged scalar or of
    # a string inside an execution result (module result / fact /
    # set_fact) that contains Jinja markers.
    def self.unsafe_text?(raw : String) : Bool
      @@texts.includes?(raw)
    end

    # Records every brace-bearing string inside an execution result
    # (*value*) - called on the per-host registered/set_fact/fact stores
    # once per task. Only strings that actually contain a Jinja marker
    # are recorded, so the common case (plain command output, ordinary
    # facts) adds nothing and costs one `includes?` per string.
    def self.mark_value(value : JSON::Any) : Nil
      case raw = value.raw
      when String
        @@texts.add(raw) if raw.includes?("{{") || raw.includes?("{%") || raw.includes?("{#")
      when Array
        raw.each { |element| mark_value(element) }
      when Hash
        raw.each_value { |element| mark_value(element) }
      end
    end

    private def self.walk(parser : YAML::PullParser) : Nil
      loop do
        case parser.kind
        when .scalar?
          tag = parser.tag
          value = parser.read_scalar
          @@texts.add(value) if tag == "!unsafe"
        when .sequence_start?
          parser.read_sequence_start
          walk(parser)
        when .mapping_start?
          parser.read_mapping_start
          walk(parser)
        when .sequence_end?, .mapping_end?
          parser.read_next
          return
        when .alias?
          parser.read_alias
        else
          return
        end
      end
    end
  end
end
