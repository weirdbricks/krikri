require "json"

module Krikri
  # AptLocale - reproduces the environment real apt.py wraps EVERY
  # apt command in. AnsibleModule-based modules set
  # `run_command_environ_update` once, and every command they run through
  # `module.run_command` (install, remove, upgrade, the cache update, the
  # dpkg probes) inherits it - apt.py's APT_ENV_VARS:
  # DEBIAN_FRONTEND=noninteractive, DEBIAN_PRIORITY=critical, and
  # LANG/LC_ALL/LC_MESSAGES/LC_CTYPE/LANGUAGE all set to
  # get_best_parsable_locale's result.
  #
  # get_best_parsable_locale (ansible.module_utils.common.locale) runs
  # `locale -a` on the target and returns the first of
  # ['C.utf8', 'C.UTF-8', 'en_US.utf8', 'en_US.UTF-8', 'C', 'POSIX'] that
  # the target actually has, falling back to 'C' when the tool is missing,
  # fails, or prints nothing. On the stock Ubuntu/Debian images the
  # benchmark roles run against that is C.UTF-8's variant - NOT the
  # hardcoded 'C' this engine used to force (issue #449,
  # ccdc.cpp_gui_dev_tools: systemd's "Created symlink" message prints the
  # UTF-8 arrow only under a UTF-8 locale and plain "->" under 'C', so the
  # captured apt-get stdout diverged from Ansible's byte for byte on every
  # symlink a dependency chain's postinst created).
  #
  # The locale value is validated against the same character set a locale
  # name can legally hold before it is interpolated into a shell command
  # string - Ansible hands these values through a dict, so it never faces
  # this injection surface.
  module AptLocale
    PREFERRED_LOCALES = ["C.utf8", "C.UTF-8", "en_US.utf8", "en_US.UTF-8", "C", "POSIX"]

    # get_best_parsable_locale's exact preference order over `locale -a`'s
    # output; every failure mode (missing tool, nonzero exit, empty output)
    # falls back to plain 'C' the same way.
    def best_parsable_locale(&remote : String -> NamedTuple(exit_code: Int32, stdout: String, stderr: String)) : String
      result = remote.call("locale -a")
      return "C" unless result[:exit_code] == 0
      return "C" if result[:stdout].strip.empty?
      available = result[:stdout].split("\n").map(&.strip).reject(&.empty?)
      PREFERRED_LOCALES.each do |pref|
        return pref if available.includes?(pref)
      end
      "C"
    end

    # The full APT_ENV_VARS dict as a command-string prefix, in apt.py's
    # own key order. Callers memoize the result - the probe costs one
    # command round trip and Ansible probes once per module run too.
    def apt_env_prefix(&remote : String -> NamedTuple(exit_code: Int32, stdout: String, stderr: String)) : String
      locale = best_parsable_locale { |cmd| remote.call(cmd) }
      locale = "C" unless locale.matches?(/\A[A-Za-z0-9_.@+-]+\z/)
      "DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical LANG=#{locale} LC_ALL=#{locale} LC_MESSAGES=#{locale} LC_CTYPE=#{locale} LANGUAGE=#{locale}"
    end
  end
end
