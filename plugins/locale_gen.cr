#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/locale_gen_command"

module Krikri
  # locale_gen plugin - a native port of community.general.locale_gen
  # (read from a live collection install; Debian/Ubuntu is a supported
  # platform here, per the real module's own NOTES).
  #
  # Follows the real module's control flow:
  #   - mechanism selection: /etc/locale.gen present -> glibc;
  #     /var/lib/locales/supported.d/ present -> ubuntu_legacy
  #     (deprecated upstream, ported anyway since roles still hit it);
  #     neither -> the real module's "Is the package 'locales'
  #     installed?" failure
  #   - assert_available: every requested locale must appear in
  #     /usr/share/i18n/SUPPORTED (or /usr/local/share/i18n/SUPPORTED)
  #     or already be compiled per `locale -a`; otherwise the real
  #     module's "locales you have entered are not available" failure
  #   - presence: `locale -a` lines compared through the real module's
  #     LOCALE_NORMALIZATION case-folding (en_US.utf8 == en_US.UTF-8)
  #   - glibc apply: comment/uncomment the locale's line in
  #     /etc/locale.gen, then run locale-gen; ubuntu_legacy apply:
  #     plain locale-gen to add, or filter
  #     /var/lib/locales/supported.d/local + locale-gen --purge to
  #     remove (the real module's "regenerate everything" behavior,
  #     kept as-is)
  #   - `name:` accepts the post-9.3.0 list form and the legacy single
  #     string; check mode skips the apply
  class LocaleGenPlugin < BasePlugin
    ETC_LOCALE_GEN        = "/etc/locale.gen"
    VAR_LIB_LOCALES       = "/var/lib/locales/supported.d"
    VAR_LIB_LOCALES_LOCAL = "/var/lib/locales/supported.d/local"
    SUPPORTED_LOCALES     = ["/usr/share/i18n/SUPPORTED", "/usr/local/share/i18n/SUPPORTED"]

    def execute : PluginResult
      names = parse_names
      return PluginResult.new(changed: false, failed: true,
        msg: "missing required argument: name") if names.empty?

      state = @params["state"]? || "present"
      return PluginResult.new(changed: false, failed: true,
        msg: "value of state must be one of: present, absent, got #{state}") unless ["present", "absent"].includes?(state)

      mechanism = detect_mechanism
      return mechanism if mechanism.is_a?(PluginResult)

      check_mode = true?(@params["check_mode"]?)

      locale_a = remote_exec("locale -a")
      locale_a_output = locale_a[:exit_code] == 0 ? locale_a[:stdout] : ""

      not_present = locale_get_not_present(names, locale_a_output)

      # assert_available - against the SUPPORTED files only for the
      # locales `locale -a` doesn't already list as compiled.
      unavailable = not_present.reject do |locale|
        available = false
        SUPPORTED_LOCALES.each do |path|
          result = remote_exec("cat #{shell_single_quote(path)} 2>/dev/null")
          next unless result[:exit_code] == 0
          available ||= PluginHelpers::LocaleGenCommand.locale_available?(locale, result[:stdout].split("\n"), "")
          break if available
        end
        available
      end
      unless unavailable.empty?
        return PluginResult.new(changed: false, failed: true,
          msg: "The following locales you have entered are not available on your system: #{unavailable.join(", ")}")
      end

      changed = not_present.any?
      if changed && !check_mode
        apply_result = state == "present" ? apply_change_present(mechanism.as(String), names) : apply_change_absent(mechanism.as(String), names)
        return apply_result if apply_result
      end

      PluginResult.new(changed: changed, failed: false, msg: "state: #{state}",
        mechanism: mechanism.as(String), state: state)
    end

    private def parse_names : Array(String)
      raw = @params["name"]?
      return [] of String unless raw

      begin
        parsed = JSON.parse(raw)
        return parsed.as_a.map(&.as_s) if parsed.as_a?
        return [parsed.as_s] if parsed.as_s? && !parsed.as_s.empty?
      rescue
      end

      return [] of String if raw.empty?
      raw.includes?(",") ? raw.split(",").map(&.strip).reject(&.empty?) : [raw]
    end

    private def detect_mechanism : (String | PluginResult)
      if remote_file_exists?(ETC_LOCALE_GEN)
        "glibc"
      elsif remote_file_exists?(VAR_LIB_LOCALES)
        "ubuntu_legacy"
      else
        PluginResult.new(changed: false, failed: true,
          msg: "#{VAR_LIB_LOCALES} and #{ETC_LOCALE_GEN} are missing. Is the package \"locales\" installed?")
      end
    end

    # Real module's locale_get_not_present: a requested locale counts
    # as present when some `locale -a` line equals it after
    # LOCALE_NORMALIZATION folding.
    private def locale_get_not_present(names : Array(String), locale_a_output : String) : Array(String)
      names.reject do |locale|
        locale_a_output.split("\n").any? do |line|
          folded = PluginHelpers::LocaleGenCommand.fix_case(line.strip)
          !folded.empty? && folded == PluginHelpers::LocaleGenCommand.fix_case(locale)
        end
      end
    end

    private def apply_change_present(mechanism : String, names : Array(String)) : PluginResult?
      if mechanism == "glibc"
        set_locale_glibc(names, enabled: true)
        run_locale_gen("")
      else
        run_locale_gen("")
      end
    end

    private def apply_change_absent(mechanism : String, names : Array(String)) : PluginResult?
      if mechanism == "glibc"
        set_locale_glibc(names, enabled: false)
        run_locale_gen("")
      else
        content = remote_exec("cat #{shell_single_quote(VAR_LIB_LOCALES_LOCAL)} 2>/dev/null")
        if content[:exit_code] == 0
          kept = content[:stdout].lines.reject do |line|
            locale = line.split(" ").first?
            locale ? names.includes?(locale) : false
          end
          write_remote_file(VAR_LIB_LOCALES_LOCAL, kept.empty? ? "" : kept.join("\n") + "\n")
        end
        run_locale_gen(" --purge")
      end
    end

    # The real module's set_locale_glibc: rewrite /etc/locale.gen with
    # each requested locale's line commented in/out, charset column
    # preserved. Read/transform/write happens on the target host - the
    # plugin binary itself runs there (see BasePlugin's note on the
    # plugin filesystem being the remote filesystem).
    private def set_locale_glibc(names : Array(String), enabled : Bool) : Nil
      read = remote_exec("cat #{shell_single_quote(ETC_LOCALE_GEN)} 2>/dev/null")
      return unless read[:exit_code] == 0

      rewritten = PluginHelpers::LocaleGenCommand.rewrite_locale_gen(read[:stdout].lines, names, enabled)
      write_remote_file(ETC_LOCALE_GEN, rewritten.empty? ? "" : rewritten.join("\n") + "\n")
    end

    private def write_remote_file(path : String, content : String) : Nil
      remote_exec("printf '%s' #{shell_single_quote(content)} > #{shell_single_quote(path)}")
    end

    private def run_locale_gen(extra_args : String) : PluginResult?
      result = remote_exec("locale-gen#{extra_args}")
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true,
          msg: "locale-gen failed: #{result[:stderr].strip}")
      end
      nil
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::LocaleGenPlugin.new(config)
plugin.run
