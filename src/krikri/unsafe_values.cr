require "yaml"

module Krikri
  # Registry of UNSAFE TEXTS - strings that are verbatim content, never
  # template text, wherever they surface. Two sources feed it:
  #
  # - YAML `!unsafe`-tagged scalars (Ansible's `!unsafe` tag: "this
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
  #   copy - ansible-core's taint follows the data, and a hostile
  #   target must not get controller code execution by returning stdout
  #   shaped like `{{ lookup('pipe', ...) }}` no matter how many author
  #   templates relay it.
  #
  # The re-render gates consult #unsafe_text? alongside the per-host
  # unsafe-name registry: a value whose exact text is registered here is
  # passed through verbatim on every evaluation path.
  #
  # The registry is closed under DERIVATION: every render whose output
  # was demonstrably fed by a registered/execution-resolved string is
  # itself recorded (#mark_unsafe at the span gate, #mark_derived for
  # whole-text concatenation), so the set tracks ansible-core's
  # taint-follows-the-data type across transforms that change the text
  # (`| trim`, `| lower`) and through author templates that relay it.
  module UnsafeValues
    @@texts = Set(String).new

    # Scans *text* (a YAML document about to be parsed) for `!unsafe`
    # -tagged scalars and records their values. Cheap when the document
    # contains no tag at all; a malformed document must never fail the
    # real parse that follows, so any pull-parser error is swallowed.
    # A parseABLE document whose walk still fails (any non-parse
    # exception mid-walk) must neither crash the run nor silently
    # disable marking: the walk degrades to a partial pass (scalars
    # recorded before the failure stay registered - the registry only
    # grows) and the abort is surfaced as a warning, because an
    # unmarked `!unsafe` scalar is a silently disabled security control.
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
      rescue ex : Exception
        STDERR.puts "[WARNING]: !unsafe pre-scan aborted mid-document (#{ex.class}: #{ex.message}); any !unsafe scalars after the failure point were NOT marked and will be treated as template text. Document began with: #{text.byte_slice(0, 120)}"
      end
    end

    # Whether *raw* is the exact text of a `!unsafe`-tagged scalar or of
    # a string inside an execution result (module result / fact /
    # set_fact) that contains Jinja markers.
    def self.unsafe_text?(raw : String) : Bool
      @@texts.includes?(raw)
    end

    # Whether *text* embeds any registered hostile text as a substring -
    # the read-only twin of #mark_derived's own scan. The exact-text
    # registry holds the LEAF strings of an execution result, so a
    # container's stringified form (`["{{ ... }}"]`, `{"k": "{{ ... }}"}`)
    # is a member nowhere, yet every hostile leaf it carries appears in it
    # verbatim - a re-render decision on that text must treat it as
    # tainted exactly like ansible-core's taint-follows-the-data
    # model, or the hostile leaves inside the container get rendered as
    # controller-side template text (a task-level `vars: b: "{{ r.stdout_
    # lines }}"` re-rendered the whole-list repr and executed a
    # `lookup('pipe', ...)` the module result merely carried as data).
    # Same cost model as #mark_derived: only called on text that still
    # contains a Jinja marker.
    def self.contains_unsafe?(text : String) : Bool
      return false unless text.includes?("{{") || text.includes?("{%") || text.includes?("{#")
      @@texts.any? { |hostile| text.includes?(hostile) }
    end

    # Records *text* as hostile with no substring scan - the DERIVATION
    # closure of the registry. Callers invoke it exactly where an
    # evaluation path has just established that a render's OUTPUT was fed
    # by execution-resolved data (the span gate saw a resolved root in the
    # expression, a registered hostile inside the output, or a resolved
    # hostvars origin). ansible-core types that output
    # AnsibleUnsafeText and every later decision honors the type; krikri
    # has no string type to piggyback on, so the derivation is recorded
    # here the moment it happens - otherwise a transform that alters the
    # registered text (`| trim`, `| lower`, concatenation relayed through
    # an author variable) produced a string that neither the name gate
    # (the flattened value surfaces under no resolved name) nor the
    # substring scan (the text no longer contains any registered leaf)
    # could recognise, and it was re-rendered as template text.
    # Same cost model as the rest of the registry: only brace-bearing
    # output is ever stored.
    def self.mark_unsafe(text : String) : Nil
      return unless text.includes?("{{") || text.includes?("{%") || text.includes?("{#")
      @@texts.add(text)
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

    # Records *text* when it is a DERIVED string - a render whose output
    # embedded a registered hostile text (an author template like
    # `loop: ["{{ r.stdout }}-suffix"]` pulls the hostile result value in
    # as data; the concatenated output is itself unsafe exactly like real
    # ansible-core's taint-follows-the-data model). The exact-text
    # registry alone cannot see the derived string, so without this the
    # hostile braces embedded in it would be re-rendered as template text
    # the next time the value surfaces (e.g. `msg: "{{ item }}"` over the
    # derived loop item). Substring match against the registry: any
    # output containing a registered hostile text was necessarily fed by
    # it (or coincides with it, which is the same verdict). Cheap: the
    # scan only runs when the output still contains a Jinja marker, which
    # after a normal render means hostile content survived in it.
    def self.mark_derived(text : String) : Nil
      return unless text.includes?("{{") || text.includes?("{%") || text.includes?("{#")
      derived = false
      @@texts.each do |hostile|
        next if hostile == text
        if text.includes?(hostile)
          derived = true
          break
        end
      end
      @@texts.add(text) if derived
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
