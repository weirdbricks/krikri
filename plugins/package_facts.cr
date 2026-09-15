#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # PackageFacts Plugin - populate the ansible_facts.packages dict with the
  # installed packages, matching ansible.builtin.package_facts (manager:
  # auto). The fact shape follows real Ansible: a dict keyed by package name
  # with each value a list of one-or-more dicts describing an installed
  # version, e.g. {
  #   "libpam-modules" => [{"name" => "libpam-modules", "version" => "1.4.0-19"}]
  # }.
  #
  # manager: auto resolves to dpkg on Debian/Ubuntu (queried via dpkg-query
  # for its authoritative package/version list); rpm would be used on
  # EL/RedHat-family hosts but os_hardening's package_facts usage guards on
  # os_family != Suse/Archlinux, so dpkg is the path the role actually
  # needs. Read-only, so it's safe under --check.
  #
  # Param coverage matches real Ansible's argument_spec
  # (ansible/modules/package_facts.py):
  #   manager:  type list (default ['auto']), lowercased, with real's
  #             ALIASES (dnf/dnf5/yum/zypper -> rpm; added in ansible-core
  #             2.18). There is deliberately NO "dpkg" manager: real
  #             Ansible - every version - fails "Unsupported package
  #             managers requested: dpkg" (dpkg-query is this engine's
  #             implementation detail of the apt manager, not a real
  #             manager name).
  #             'auto' expands to real's full PKG_MANAGER_NAMES (only apt
  #             and rpm are gatherable here), keeping user order (real
  #             appends the full sorted name list and drops 'auto' - same
  #             shape, restricted to managers this engine can actually
  #             query).
  #   strategy: 'first' (default) stops at the first manager that yielded a
  #             NON-EMPTY package list; 'all' queries every manager in the
  #             list. When several managers report the SAME package name,
  #             real Ansible (package_facts.py main(), the
  #             `packages[k].extend(packages_found[k])` branch) appends the
  #             later manager's entries onto the existing name's list - the
  #             package appears once in the dict, with entries from every
  #             manager that reported it, not under a separate key and not
  #             overwritten. strategy 'first' therefore never shows a
  #             cross-manager collision; 'all' does. This plugin mirrors
  #             that extend-per-name merge exactly.
  #
  # Failure paths also match real Ansible's wording (verified live against
  # ansible-core 2.19.4):
  #   - an unknown manager name fails immediately with "Unsupported package
  #     managers requested: <names>" (real code's unsupported-set check,
  #     before any gathering) - or, when the request also contained 'auto',
  #     with real's different "Could not auto detect a usable package
  #     manager, check warnings for details." wording for the same
  #     unsupported-name condition;
  #   - known-but-unusable managers just gather nothing (real code's warn
  #     + keep-going path), and only if NO manager yielded packages does
  #     the task fail with "Could not detect a supported package manager
  #     from the following list: [...], or the required Python library is
  #     not installed. Check warnings for details."
  class PackageFactsPlugin < BasePlugin
    # krikri's gatherable set, in real Ansible's sorted-name order (apt
    # before rpm) so 'auto' expansion order matches the real module's
    # iteration order.
    AUTO_DETECT_MANAGERS = ["apt", "rpm"]

    # Canonical names this engine can gather + real Ansible's ALIASES
    # (package_facts.py, added in ansible-core 2.18). No "dpkg": real
    # Ansible has no dpkg manager and fails it as unsupported (verified
    # live vs ansible-core 2.14 AND 2.19), and dpkg-query is only this
    # engine's implementation detail of the apt manager.
    CANONICAL_MANAGERS = {
      "apt"    => "apt",
      "rpm"    => "rpm",
      "dnf"    => "rpm",
      "dnf5"   => "rpm",
      "yum"    => "rpm",
      "zypper" => "rpm",
    }

    def execute : PluginResult
      strategy = (@params["strategy"]? || "first").to_s
      unless ["first", "all"].includes?(strategy)
        # Real AnsibleModule argument_spec choices error, verified live:
        # `value of strategy must be one of: first, all, got: bogus`.
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "value of strategy must be one of: first, all, got: #{strategy}"
        )
      end

      requested = parse_manager_list((@params["manager"]? || "auto").to_s).map(&.downcase)

      bad = requested.reject { |mgr_name| CANONICAL_MANAGERS.has_key?(mgr_name) || mgr_name == "auto" }
      unless bad.empty?
        # Real module fails BEFORE gathering anything, and the message
        # differs depending on whether 'auto' was among the requested
        # names (real code's `if 'auto' in module.params['manager']`
        # branch, verified live): with 'auto' present it's
        # "Could not auto detect a usable package manager, check warnings
        # for details.", without it "Unsupported package managers
        # requested: bogusmgr".
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: requested.includes?("auto") \
            ? "Could not auto detect a usable package manager, check warnings for details." \
            : "Unsupported package managers requested: #{bad.join(", ")}"
        )
      end

      # 'auto' expands in place: real code appends every known manager name
      # after the user's entries then removes 'auto', preserving user order.
      managers = requested.dup
      if requested.includes?("auto")
        managers.concat(AUTO_DETECT_MANAGERS)
        managers.delete("auto")
      end

      packages = Hash(String, JSON::Any).new
      found = 0
      seen = Set(String).new
      managers.each do |mgr|
        break if strategy == "first" && found > 0

        canonical = CANONICAL_MANAGERS[mgr]? || mgr
        next if seen.includes?(canonical)
        seen << canonical

        entries = canonical == "rpm" ? rpm_packages : apt_packages
        # Real code only counts a manager as 'found' when it yields a
        # non-empty dict; an unusable one just warns and keeps going.
        next if entries.empty?
        found += 1

        entries.each do |name, list|
          if existing = packages[name]?
            packages[name] = JSON::Any.new(existing.as_a + list.as_a)
          else
            packages[name] = list
          end
        end
      end

      return no_manager_result(managers) if found == 0

      PluginResult.new(
        changed: false,
        failed: false,
        msg: "Gathered #{packages.size} package facts",
        ansible_facts: JSON::Any.new({"packages" => JSON::Any.new(packages)})
      )
    end

    # Real Ansible's `manager` is a list; in YAML a scalar string is also
    # accepted (single element, or comma-separated - real AnsibleModule's
    # check_type_list splits those). A templated expression that resolved
    # to a real list reaches the plugin as a JSON-array string (same
    # convention unarchive.cr's parse_list_param documents). ONLY valid
    # JSON - never a Python-repr repair pass: a value that merely LOOKS
    # like a container is a plain STRING in real ansible-core
    # (live-verified vs ansible-playbook 2.19.11, see apt.cr's
    # parse_package_names); a `{% if %}`-rendered "list" is such a
    # string.
    private def parse_manager_list(raw : String) : Array(String)
      return ["auto"] if raw.empty?
      if raw.starts_with?('[')
        (Array(String).from_json(raw) rescue nil).try { |parsed| return parsed }
      end
      raw.split(",").map(&.strip).reject(&.empty?)
    end

    private def command_available?(cmd : String) : Bool
      !Process.find_executable(cmd).nil?
    end

    # Real Ansible's found==0 failure, phrased with the (post-expansion)
    # manager list and verified live against ansible-core 2.19.4:
    # "Could not detect a supported package manager from the following
    # list: ['rpm'], or the required Python library is not installed.
    # Check warnings for details."
    private def no_manager_result(managers : Array(String)) : PluginResult
      listed = managers.map { |mgr_name| "'#{mgr_name}'" }.join(", ")
      PluginResult.new(
        changed: false,
        failed: true,
        msg: "Could not detect a supported package manager from the following list: [#{listed}], or the required Python library is not installed. Check warnings for details."
      )
    end

    # dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\t${Section}\n'
    # prints one line per package. Repeated prefixes/architectures could
    # yield the same name again; the dict maps name -> [entry...], matching
    # real Ansible where a package present in multiple
    # architectures/versions appears as a list. Real Ansible's apt manager
    # (python-apt) stamps every entry with source: apt plus arch/category
    # (RETURN doc + live-verified entry keys: arch, category, name, origin,
    # source, version) - origin is python-apt's repo-Release-file Origin
    # (e.g. "Debian"), which dpkg-query has no equivalent field for, so
    # apt_release_origin reads it from /var/lib/apt/lists instead (""
    # matches python-apt's when no apt lists exist, e.g. the
    # origins[0].origin == '' "now" archive case).
    private def apt_packages : Hash(String, JSON::Any)
      result = Hash(String, JSON::Any).new
      origin = apt_release_origin
      stdout = capture("dpkg-query", ["-W", "-f=${Package}\\t${Version}\\t${Architecture}\\t${Section}\\n"])
      stdout.each_line do |line|
        line = line.strip
        parts = line.split("\t")
        next unless parts.size == 4
        name, version, arch, category = parts
        next if name.empty?
        entry = JSON::Any.new({
          "name"     => JSON::Any.new(name),
          "version"  => JSON::Any.new(version),
          "arch"     => JSON::Any.new(arch),
          "category" => JSON::Any.new(category),
          "origin"   => JSON::Any.new(origin),
          "source"   => JSON::Any.new("apt"),
        })
        list = result[name]?.try(&.as_a?) || [] of JSON::Any
        list << entry
        result[name] = JSON::Any.new(list)
      end
      result
    end

    # The repo-Release Origin (e.g. "Debian") python-apt reports as each
    # entry's origin: read from the first apt list's Release/InRelease
    # header. InRelease files have a PGP wrapper before the headers, so
    # scan lines rather than assuming a header block at the top.
    private def apt_release_origin : String
      files = Dir.glob("/var/lib/apt/lists/*_InRelease") + Dir.glob("/var/lib/apt/lists/*_Release")
      files.each do |path|
        next unless File.file?(path)
        File.each_line(path) do |line|
          return line["Origin: ".size..].strip if line.starts_with?("Origin: ")
        end
      end
      ""
    rescue
      ""
    end

    # rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\n' gives one pkg per line.
    private def rpm_packages : Hash(String, JSON::Any)
      result = Hash(String, JSON::Any).new
      stdout = capture("rpm", ["-qa", "--qf=%{NAME}\\t%{VERSION}-%{RELEASE}\\n"])
      stdout.each_line do |line|
        line = line.strip
        parts = line.split("\t")
        next unless parts.size == 2
        name, version = parts
        next if name.empty?
        entry = JSON::Any.new({
          "name"    => JSON::Any.new(name),
          "version" => JSON::Any.new(version),
          "source"  => JSON::Any.new("rpm"),
        })
        list = result[name]?.try(&.as_a?) || [] of JSON::Any
        list << entry
        result[name] = JSON::Any.new(list)
      end
      result
    end

    # Run *command* with *args* (no shell), capturing stdout only; "" on
    # failure.
    private def capture(command : String, args : Array(String)) : String
      output = IO::Memory.new
      Process.run(command, args, output: output, error: Process::Redirect::Close)
      output.to_s.strip
    rescue
      ""
    end
  end
end

# Entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::PackageFactsPlugin.new(config)
plugin.run
