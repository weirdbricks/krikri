module Krikri
  module PluginHelpers
    # LocaleGenCommand - the pure string logic of
    # community.general.locale_gen, split out of the plugin so the
    # normalization table, the /usr/share/i18n/SUPPORTED entry matcher
    # and the /etc/locale.gen rewrite are unit-testable without a
    # Debian host (or a locales package). The plugin executes the
    # commands these build on (`locale -a`, `locale-gen`).
    module LocaleGenCommand
      # Real module's LOCALE_NORMALIZATION: `locale -a` reports
      # encodings in either case (en_US.utf8 vs en_US.UTF-8), so both
      # sides of every comparison pass through this table first.
      LOCALE_NORMALIZATION = {
        ".utf8"      => ".UTF-8",
        ".eucjp"     => ".EUC-JP",
        ".iso885915" => ".ISO-8859-15",
        ".cp1251"    => ".CP1251",
        ".koi8r"     => ".KOI8-R",
        ".armscii8"  => ".ARMSCII-8",
        ".euckr"     => ".EUC-KR",
        ".gbk"       => ".GBK",
        ".gb18030"   => ".GB18030",
        ".euctw"     => ".EUC-TW",
      }

      def self.fix_case(name : String) : String
        LOCALE_NORMALIZATION.each do |suffix, replacement|
          name = name.gsub(suffix, replacement)
        end
        name
      end

      # A /usr/share/i18n/SUPPORTED entry line, e.g. "en_US.UTF-8 UTF-8"
      # or a commented "# de_LI.UTF-8 UTF-8". Mirrors the real module's
      # re_locale_entry, including that the locale group is
      # `\S+[._\S]+` - the trailing charset is whatever follows the
      # LAST space the backtracking engine can still hand to it.
      SUPPORTED_ENTRY_RE = /^\s*#?\s*(?<locale>\S+[._\S]+) (?<charset>\S+)\s*$/

      def self.supported_entry_locale(line : String) : String?
        match = SUPPORTED_ENTRY_RE.match(line.strip)
        match.try(&.["locale"])
      end

      # assert_available: a requested locale must appear as an entry in
      # one of the SUPPORTED files, OR already be compiled (listed by
      # `locale -a` - covers e.g. C.UTF-8, which some systems don't
      # list in SUPPORTED). Comparison goes through fix_case on both
      # sides.
      def self.locale_available?(locale : String, supported_lines : Array(String), locale_a_output : String) : Bool
        return true if locale_a_output.split("\n").any? { |line| fix_case(line.strip) == fix_case(locale) && !line.strip.empty? }
        supported_lines.any? { |line| supported_entry_locale(line) == locale }
      end

      # set_locale_glibc: comment out (`enabled: false`) or uncomment
      # (`enabled: true`) one entry per requested locale in
      # /etc/locale.gen, preserving each line's charset column. Real
      # module's regex is `^#?\s*<name> (?P<charset>.+)`; it applies
      # the sub to every line, and a line that doesn't match is
      # returned unchanged - which is also what makes this idempotent
      # (an already-enabled line matches and rewrites to itself).
      def self.rewrite_locale_gen(lines : Array(String), names : Array(String), enabled : Bool) : Array(String)
        lines.map do |line|
          rewritten = line
          names.each do |name|
            re = /^#?\s*#{Regex.escape(name)} (?<charset>.+)$/
            if match = re.match(rewritten)
              rewritten = enabled ? "#{name} #{match["charset"]}" : "# #{name} #{match["charset"]}"
            end
          end
          rewritten
        end
      end
    end
  end
end
