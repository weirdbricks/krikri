module Krikri
  module PluginHelpers
    # Batched "what does the host already know about these specs?" probing
    # for the RPM-family package plugins (dnf.cr, yum.cr via RpmPackage,
    # and package.cr's own dnf backend).
    #
    # Ansible's dnf module hands a whole `name:` list to ONE depsolve, so
    # its cost is flat in the number of names. This engine answered
    # "installed? / available in the repos? / provided by something?" per
    # name, each answer a separate process spawn: a `perl(Foo::Bar)`
    # capability list therefore paid ~2.7s per entry (one dnf4 CLI startup
    # each - dnf4 only answers the repo-row question through the CLI,
    # there is no cheap alternative) and a 75-name list took minutes
    # (issue #904). Both questions the RPM database can answer itself are
    # collected here in a SINGLE round trip for the whole list, so only
    # the repo-row question needs one dnf invocation per list rather than
    # one per name.
    #
    # Specs rpm can answer ambiguously (shell globs would expand to
    # thousands of rows, and a newline would break the marker framing) are
    # rejected by #rpm_probe_batchable? so their callers keep the old
    # per-spec path for them.
    module RpmSpecProbe
      # Line prefix framing each spec's probe section. Chosen to be
      # unprintable-by-rpm so package output can never forge a marker.
      PROBE_MARKER = "==KRIKRI-RPM-PROBE=="

      # A spec whose rpm answer is unambiguous and safe to embed in the
      # batched command's marker framing.
      private def rpm_probe_batchable?(spec : String) : Bool
        !spec.empty? && !spec.matches?(/[*?\[\]\n\r]/)
      end

      # The queryformat every plugin asking for an installed NEVRA passes:
      # name-version-release.arch, the spelling the dnf module's own
      # results entries carry.
      RPM_NEVRA_QUERYFORMAT = "%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}"

      private alias RpmSpecProbeAnswer = NamedTuple(installed: Bool, nevra: String, provides: Bool)

      # One round trip answering, per spec, whether a package with that
      # exact name is installed (plus its NEVRA under *queryformat*) and
      # whether any installed package Provides: it. Missing entries mean
      # the probe produced no parseable answer for that spec, which every
      # caller reads as "not installed, not provided" - the same verdict a
      # failed per-spec `rpm -q` gives.
      private def rpm_spec_probes(specs : Array(String), queryformat : String) : Hash(String, RpmSpecProbeAnswer)
        answers = Hash(String, RpmSpecProbeAnswer).new
        unique = specs.uniq.reject(&.empty?)
        return answers if unique.empty?

        parsed = parse_rpm_probe_output(remote_exec(rpm_probe_command(unique, queryformat))[:stdout])

        unique.each do |one|
          nevra = parsed[:installed_nevras][one]? || ""
          answers[one] = {installed: !nevra.empty?, nevra: nevra, provides: parsed[:provides][one]? || false}
        end
        answers
      end

      # The whole list's probe as ONE shell command, one section per spec.
      private def rpm_probe_command(specs : Array(String), queryformat : String) : String
        specs.map { |spec| rpm_probe_step(spec, queryformat) }.join("; ")
      end

      private def rpm_probe_step(spec : String, queryformat : String) : String
        quoted = shell_single_quote(spec)
        # rpm reports "package X is not installed" on STDOUT, so the
        # nevra is only trusted when the exit status says the query found
        # something. That status rides its own marker line, which is
        # PRINTED by printf with a leading newline: a successful
        # `rpm -q --qf` emits no trailing newline, so a plain echo marker
        # would be glued onto the end of the nevra.
        "#{probe_echo("q#{spec}")}; " \
        "rpm -q --qf #{shell_single_quote(queryformat)} #{quoted} 2>/dev/null; " \
        "printf '\\n%s\\n' #{shell_single_quote(PROBE_MARKER + "s")}$?; " \
        "#{probe_echo("p#{spec}")}; " \
        "rpm -q --whatprovides #{quoted} >/dev/null 2>&1 && echo Y || echo N"
      end

      private alias RpmProbeSections = NamedTuple(installed_nevras: Hash(String, String), provides: Hash(String, Bool))

      # Splits the batched probe output back into per-spec answers: the
      # nevra lines a spec's `q` marker introduced, and the Y/N line its
      # `p` marker introduced.
      private def parse_rpm_probe_output(output : String) : RpmProbeSections
        installed_nevras = {} of String => String
        provides = {} of String => Bool
        section : Char? = nil
        spec = ""
        buffer = [] of String

        output.each_line do |line|
          if tag = rpm_probe_tag(line)
            section, spec, buffer = apply_rpm_probe_tag(tag, spec, buffer, installed_nevras)
          elsif section == 'q'
            buffer << line
          elsif section == 'p' && !line.strip.empty?
            provides[spec] = line.strip == "Y"
          end
        end

        {installed_nevras: installed_nevras, provides: provides}
      end

      # A marker line's payload (section kind character plus the spec it
      # belongs to), or nil for a line rpm itself printed.
      private def rpm_probe_tag(line : String) : String?
        line.starts_with?(PROBE_MARKER) ? line.lchop(PROBE_MARKER) : nil
      end

      # Applies one marker line, yielding the (section, spec, buffer)
      # state that follows it. An unrecognized kind drops the section
      # rather than misattributing later lines to it.
      private def apply_rpm_probe_tag(tag : String, spec : String, buffer : Array(String), installed_nevras : Hash(String, String)) : {Char?, String, Array(String)}
        rest = tag.size > 1 ? tag[1..] : ""
        case tag[0]?
        when 'q'
          {'q', rest, [] of String}
        when 's'
          collected = buffer.map(&.strip).reject(&.empty?)
          installed_nevras[spec] = collected.join(" ") if rest.strip == "0" && collected.size == 1
          {nil, spec, buffer}
        when 'p'
          {'p', rest, buffer}
        else
          {nil, spec, buffer}
        end
      end

      private def probe_echo(tag : String) : String
        "echo #{shell_single_quote(PROBE_MARKER + tag)}"
      end

      # Whether a `dnf list --available` row for the package *row_name*
      # answers the requested *spec*. dnf resolves a spec as
      # `name[-version]` (and `name.arch`), so "bash-5.1.8" is answered by
      # the `bash` row while "bash-tools" is not - the version suffix
      # starts with a digit, a longer name does not.
      private def rpm_repo_row_matches?(row_name : String, spec : String) : Bool
        return true if spec == row_name
        return true if spec.starts_with?("#{row_name}.") && spec.size > row_name.size + 1
        suffix = spec.lchop("#{row_name}-")
        return false if suffix.size == spec.size || suffix.empty?
        suffix[0].ascii_number?
      end
    end
  end
end
