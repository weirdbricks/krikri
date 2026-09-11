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
  class PackageFactsPlugin < BasePlugin
    def execute : PluginResult
      manager = (@params["manager"]? || "auto").to_s
      packages = Hash(String, JSON::Any).new

      case manager
      when "auto"
        if command_available?("dpkg-query")
          packages = dpkg_packages
        elsif command_available?("rpm")
          packages = rpm_packages
        end
      when "dpkg", "apt"
        # Real Ansible's package_facts module accepts "apt" as its own
        # explicit manager value (distinct from "auto"/"dpkg" - it
        # queries via python-apt bindings instead of dpkg-query), but
        # produces the same {name => [{"name", "version"}]} fact shape
        # on a Debian/Ubuntu host - found via nvidia.enroot's own
        # `package_facts: manager: apt`, which this plugin previously
        # rejected outright as "Unsupported package manager: apt" (the
        # case dispatch only ever recognized "auto"/"dpkg"/"rpm").
        #
        # Unlike "auto" (which probes both tools and just gathers
        # nothing if neither exists - matching real Ansible's own
        # graceful "no packages found" for auto-detection), an
        # EXPLICITLY requested manager whose backing tool isn't
        # installed must fail the task, matching real Ansible's "Could
        # not detect a supported package manager ... or the required
        # library is not installed" hard error - found via
        # oVirt.engine-setup's `package_facts: manager: rpm` on an
        # Ubuntu host with no `rpm` binary: this plugin used to call
        # `capture("rpm", ...)` unconditionally, and `capture` swallows
        # the "no such executable" exception into "" (see below), so
        # the task silently reported success with zero packages instead
        # of failing like real Ansible does.
        return unsupported_manager_result(manager) unless command_available?("dpkg-query")
        packages = dpkg_packages
      when "rpm"
        return unsupported_manager_result(manager) unless command_available?("rpm")
        packages = rpm_packages
      else
        return unsupported_manager_result(manager)
      end

      PluginResult.new(
        changed: false,
        failed: false,
        msg: "Gathered #{packages.size} package facts",
        ansible_facts: JSON::Any.new({"packages" => JSON::Any.new(packages)})
      )
    end

    private def command_available?(cmd : String) : Bool
      !Process.find_executable(cmd).nil?
    end

    # Real Ansible's package_facts phrases both cases - an unknown manager
    # name and a known one whose backing tool/library isn't present - as
    # "could not detect a supported package manager", so this mirrors that
    # rather than inventing a separate wording per case.
    private def unsupported_manager_result(manager : String) : PluginResult
      PluginResult.new(
        changed: false,
        failed: true,
        msg: "Could not detect a supported package manager from the following list: ['#{manager}'], or the required library is not installed."
      )
    end

    # dpkg-query -W -f='${Package}\t${Version}\n' prints one "pkg<TAB>ver"
    # per line. Repeated prefixes/architectures could yield the same name
    # again; the dict maps name -> [entry...], matching real Ansible where a
    # package present in multiple architectures/versions appears as a list.
    private def dpkg_packages : Hash(String, JSON::Any)
      result = Hash(String, JSON::Any).new
      stdout = capture("dpkg-query", ["-W", "-f=${Package}\\t${Version}\\n"])
      stdout.each_line do |line|
        line = line.strip
        parts = line.split("\t")
        next unless parts.size == 2
        name, version = parts
        next if name.empty?
        entry = JSON::Any.new({
          "name"    => JSON::Any.new(name),
          "version" => JSON::Any.new(version),
        })
        list = result[name]?.try(&.as_a?) || [] of JSON::Any
        list << entry
        result[name] = JSON::Any.new(list)
      end
      result
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
