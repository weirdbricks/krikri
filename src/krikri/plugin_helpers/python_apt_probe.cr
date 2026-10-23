module Krikri
  module PluginHelpers
    # PythonAptProbe - exit-status gate for ansible's own apt-manager
    # dependency. Real's apt manager (package_facts.py's APT extends
    # module_utils/facts/packages.py RespawningLibMgr) is available only
    # when SOME system python can import python3-apt: the module
    # interpreter is tried first, then real probes its respawn
    # interpreters (probe_interpreters_for_module: `<python> -c 'import
    # <lib>'`, exit status only, no shell) and respawns the whole module
    # under /usr/bin/python3. When NO candidate can import it real warns
    # and the apt manager yields nothing, so on a python3-apt-less
    # Debian/Ubuntu host even a bare `manager: auto` package_facts task
    # FAILS with the found==0 message (issue #276, robertdebock.debug).
    # krikri's apt gatherer runs dpkg-query inside this process, so
    # without an explicit gate that python3-apt requirement went
    # unobserved and the task wrongly succeeded.
    module PythonAptProbe
      # Real's respawn INTERPRETERS list is the literal
      # ['/usr/bin/python3']; the extras cover interpreters installed off
      # the standard prefix (a PATH-visible python3, /usr/bin/python) so
      # python-apt backing one of those isn't treated as absent.
      CANDIDATES = ["/usr/bin/python3", "/usr/bin/python", "python3"]

      # Both modules, not just real's probed `import apt`: python-apt's
      # import machinery pulls apt_pkg in (real's respawned
      # list_installed then reads packages through the apt_pkg-backed Cache binding), so a
      # python that imports apt but not apt_pkg is a broken python3-apt
      # install real's respawned manager would die on anyway.
      def self.imports_python_apt?(candidates : Array(String) = CANDIDATES) : Bool
        candidates.any? { |python| imports?(python) }
      end

      private def self.imports?(python : String) : Bool
        Process.run(python, ["-c", "import apt, apt_pkg"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
      rescue
        false
      end
    end
  end
end
