module CrystalPlay
  module PluginHelpers
    # LineEditor - pure line-matching/insertion logic for the lineinfile
    # plugin, factored out so it can be unit tested without touching the
    # filesystem or going through the plugin's stdin/stdout protocol.
    module LineEditor
      def self.matches_regexp?(line : String, pattern : String?) : Bool
        return false unless pattern
        regex = Regex.new(pattern)
        !!(line =~ regex)
      rescue
        false
      end

      def self.lines_equal?(a : String, b : String) : Bool
        a.strip == b.strip
      end

      # state: absent - drop every line matching regexp (or, failing that,
      # an exact match against `line`). Returns {new_lines, changed}.
      def self.remove_matching(lines : Array(String), line : String?, regexp : String?) : {Array(String), Bool}
        changed = false
        kept = lines.reject do |existing|
          should_remove = if regexp
                            matches_regexp?(existing, regexp)
                          elsif line
                            lines_equal?(existing, line)
                          else
                            false
                          end

          changed ||= should_remove
          should_remove
        end

        {kept, changed}
      end

      # state: present - ensure `line` (or a regexp-matched line, optionally
      # rewritten via backrefs) exists, inserting at insertafter/insertbefore
      # if it's missing. Returns {new_lines, changed}.
      def self.ensure_present(
        lines : Array(String),
        line : String,
        regexp : String?,
        backrefs : Bool,
        insertafter : String?,
        insertbefore : String?,
      ) : {Array(String), Bool}
        new_lines = lines.dup

        if regexp
          pattern = regexp
          # Real Ansible's lineinfile (state=present) replaces only the LAST
          # line matching the regexp, not the first. Found live benchmarking
          # geerlingguy.phpmyadmin: its `Add default username and password`
          # lineinfile tasks (regexp `^.+\[['"]host['"]\].+$`) target lines
          # that appear BOTH in the package's populated server block
          # (`...['host'] = $dbserver;`) and as a commented template near
          # EOF (`// ...['host'] = 'localhost';`). Real ansible rewrites the
          # final (commented) occurrence, leaving the active one alone;
          # crystal previously replaced the FIRST, leaving the template
          # commented and diverging config.inc.php byte-for-byte.
          found_index = new_lines.rindex { |existing| matches_regexp?(existing, pattern) }
        end

        if found_index && pattern
          if backrefs
            # Real Ansible's lineinfile backrefs mode treats `line:` as
            # a REPLACEMENT TEMPLATE for the WHOLE line (Python's
            # `match.expand(line)`, then the entire existing line is
            # overwritten by that expanded text) - not a per-match
            # substring substitution. `String#gsub(Regex, String)`
            # does the latter: it only replaces the SPAN the regexp
            # actually matched and leaves whatever wasn't matched
            # (e.g. the rest of the line after a regexp that only
            # matches a line's leading portion) appended verbatim.
            # Real bug found benchmarking riemers.gitlab-runner's own
            # "Set concurrent option": `regexp: ^(\s*)concurrent =`,
            # `line: \1concurrent = 5`, backrefs: true against the
            # existing "concurrent = 1" - the regexp only matches the
            # "concurrent =" prefix, so gsub replaced just that span
            # and left the un-matched " 1" tail in place, producing
            # the corrupt "concurrent = 5 1" (invalid TOML - gitlab-
            # runner itself then failed to parse its own config on
            # every later run: "expected a top-level item to end with
            # a newline, comment, or EOF, but got '1' instead").
            match = Regex.new(pattern).match(new_lines[found_index])
            expanded = if match
                         line.gsub(/\\(\d)/) { match[$~[1].to_i]? || "" }
                       else
                         line
                       end
            changed = expanded != new_lines[found_index]
            new_lines[found_index] = expanded
            return {new_lines, changed}
          else
            changed = new_lines[found_index] != line
            new_lines[found_index] = line
            return {new_lines, changed}
          end
        end

        # backrefs: line contains backreferences that only make sense
        # against an actual regexp match - real Ansible's own documented
        # behavior for backrefs is "if the regexp does not match anywhere
        # in the file, the file will be left unchanged" (dev-sec
        # os_hardening's own `(?!.*no_pass_expiry)` negative-lookahead
        # regexp is written specifically to stop matching once already
        # applied, relying on this - without it, a second run inserted a
        # new line with the literal, unsubstituted text "\1 ..." instead
        # of leaving the file alone).
        return {new_lines, false} if backrefs

        # Real bug found benchmarking geerlingguy.jenkins: its own
        # "Modify variables in init file." task gives a regexp: that
        # never actually matches the line it (redundantly) also passes
        # as line: - a real, if unusual, shape a real playbook can
        # write, and real Ansible's own lineinfile module still
        # recognizes the target line as already present when it finds
        # it verbatim elsewhere in the file, regardless of whether a
        # regexp: was given at all. Gating this check behind `!regexp`
        # meant ANY regexp: that failed to match (whether or not the
        # target line already existed) skipped straight to insertion -
        # a fresh duplicate `Environment="JENKINS_OPTS="` line got
        # appended on literally every single run, never converging.
        return {new_lines, false} if new_lines.any? { |existing| lines_equal?(existing, line) }

        insert_index = insertion_index(new_lines, insertafter, insertbefore)
        new_lines.insert(insert_index, line)
        {new_lines, true}
      end

      # Shared with BlockEditor, so this is public rather than private.
      def self.insertion_index(lines : Array(String), insertafter : String?, insertbefore : String?) : Int32
        if insertafter
          return lines.size if insertafter == "EOF" || insertafter == "END"
          index = lines.index { |existing| matches_regexp?(existing, insertafter) }
          index ? index + 1 : lines.size
        elsif insertbefore
          return 0 if insertbefore == "BOF" || insertbefore == "BEGIN"
          lines.index { |existing| matches_regexp?(existing, insertbefore) } || lines.size
        else
          lines.size
        end
      end
    end
  end
end
