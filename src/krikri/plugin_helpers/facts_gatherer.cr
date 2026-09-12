require "json"
require "./distribution_facts"

# The two C bindings stay at TOP level, outside the module below, and
# have to: nesting them makes `lib LibC` a brand-new lib rather than a
# re-opening of the stdlib's, which loses `GidT` (and everything else
# the stdlib declares). Several other plugins in the fat binary already
# re-open `lib LibC` the same way - `openssl_csr`/`x509_certificate`
# both add `umask` - and nothing else in the tree declares `uname`,
# `getgid` or `getpwuid`, so there is no collision to avoid here.
lib PASSWD
  struct Passwd
    pw_name : UInt8*
    pw_passwd : UInt8*
    pw_uid : UInt32
    pw_gid : UInt32
    pw_gecos : UInt8*
    pw_dir : UInt8*
    pw_shell : UInt8*
  end

  fun getpwuid(uid : UInt32) : Passwd*
end

# uname(2) and getgid(2) aren't bound by Crystal's stdlib (only getuid is),
# so they're declared here directly to avoid forking `uname`/`id -g`.
lib LibC
  UTSNAME_LENGTH = 65

  struct Utsname
    sysname : StaticArray(UInt8, 65)
    nodename : StaticArray(UInt8, 65)
    release : StaticArray(UInt8, 65)
    version : StaticArray(UInt8, 65)
    machine : StaticArray(UInt8, 65)
    domainname : StaticArray(UInt8, 65)
  end

  fun uname(buf : Utsname*) : Int32
  fun getgid : GidT
end

module Krikri
  # Perf item 2 - the fact-gathering body,
  # lifted verbatim out of `plugins/facts.cr` so the fat plugin binary
  # can link it and serve `facts` over the persistent daemon like every
  # other module.
  #
  # `facts` was the last plugin still excluded from both the fat binary
  # and the daemon, and the reason was purely SHAPE: it had no
  # `*Plugin < BasePlugin` class and no `input = STDIN.gets_to_end`
  # trailer, which is what build.sh's fat-binary generator keys on. It
  # gathers on every host in every play and is frequently the slowest
  # single step of a warm run, so it paid a fresh ssh fork + remote
  # process spawn for the one task nothing can skip.
  #
  # Everything below is the ORIGINAL top-level code, unchanged except
  # for being wrapped in this module (`extend self` keeps every internal
  # call site - `capture`, `gather_facts`, the `gather_*_facts` family -
  # resolving exactly as it did at top level). Wrapping matters: merged
  # into one binary with 80+ other plugins, top-level `def capture` and
  # a top-level re-opened `lib LibC` would be sharing a namespace with
  # every one of them.
  #
  # It is deliberately NOT reshaped into a `BasePlugin` subclass, which
  # would have needed no generator change at all: `BasePlugin#run_and_
  # capture` returns a `PluginResult`, whose `to_json` round-trips every
  # extra field through `JSON.parse(value.to_json)` - a serialize-then-
  # reparse of the whole fact dict, on the exact hot path this item
  # exists to make cheaper. It would also have added an always-empty
  # `msg` key to a payload that has never carried one.
  module FactsGatherer
    extend self

    # Runs *command* with *args* directly (no shell), capturing stdout only
    # (stderr discarded) - equivalent to `` `command 2>/dev/null` `` but without
    # forking an intermediate `/bin/sh -c`. Returns "" if the binary can't be
    # found or execution otherwise fails, matching the empty-output behavior a
    # missing command produces under the shell.
    def capture(command : String, args : Array(String) = [] of String) : String
      output = IO::Memory.new
      Process.run(command, args, output: output, error: Process::Redirect::Close)
      output.to_s.strip
    rescue
      ""
    end

    # Same as `capture`, but merges stderr into stdout - equivalent to
    # `` `command 2>&1` ``. Used for `python --version`, which some Python
    # builds print to stderr instead of stdout.
    def capture_merged(command : String, args : Array(String) = [] of String) : String
      output = IO::Memory.new
      Process.run(command, args, output: output, error: output)
      output.to_s.strip
    rescue
      ""
    end

    # The element union of the fact hash, aliased so the timed-family
    # scratch hash (gather_family_timed) can be the same shape without
    # repeating the nine-member union inline.
    alias FactValue = String | Int64 | Bool | Hash(String, String) | Array(String) | Array(Hash(String, String)) | Hash(String, JSON::Any) | Hash(String, Int64 | String) | Array(Hash(String, Int64 | String))
    alias FactSet = Hash(String, FactValue)

    # Raised for a positive gather_subset token real Ansible rejects -
    # get_collector_names raises TypeError("Bad subset '%s' given to
    # Ansible. ...") and setup's fail_json surfaces it as a module
    # failure (live-verified against 2.19.4: `gather_subset=bogus` and
    # even `gather_subset=` (empty string) both fail the module; a
    # NEGATED unknown token like `!bogus` is silently ignored there).
    class BadSubsetError < Exception
    end

    # Every subset name real ansible-core 2.19.4 accepts - the exact list
    # its own Bad-subset failure message enumerates (captured live from
    # `setup` on this machine). krikri implements only the network/
    # hardware/mounts families plus the min bundle; names that real
    # Ansible resolves to collectors krikri has no implementation for
    # (virtual, dns, selinux, ...) are ACCEPTED but gather nothing extra,
    # because failing them would break every role that uses a valid
    # subset name this engine simply has no facts for.
    VALID_SUBSETS = %w[
      all_ipv4_addresses all_ipv6_addresses apparmor architecture caps
      chroot cmdline date_time default_ipv4 default_ipv6 devices
      distribution distribution_major_version distribution_release
      distribution_version dns effective_group_ids effective_user_id env
      facter fibre_channel_wwn fips hardware interfaces is_chroot iscsi
      kernel kernel_version loadavg local lsb machine machine_id mounts
      network nvme ohai os_family pkg_mgr platform processor
      processor_cores processor_count python python_version real_user_id
      selinux service_mgr ssh_host_key_dsa_public ssh_host_key_ecdsa_public
      ssh_host_key_ed25519_public ssh_host_key_rsa_public ssh_host_pub_keys
      ssh_pub_keys system system_capabilities system_capabilities_enforced
      systemd user user_dir user_gecos user_gid user_id user_shell user_uid
      virtual virtualization_role virtualization_tech_guest
      virtualization_tech_host virtualization_type
    ]

    # Which subset tokens map to which krikri gatherer family - real
    # Ansible's aliases_map (each collector's _fact_ids): asking for a
    # single fact id like `all_ipv4_addresses` turns on that collector's
    # whole family, exactly as real Ansible's fact_id -> collector map
    # does. The min-bundle subset names (distribution, python, user, ...)
    # are absent: they resolve to the min bundle itself, which real
    # Ansible always gathers first anyway.
    FAMILY_SUBSETS = {
      "network"  => %w[network all_ipv4_addresses all_ipv6_addresses default_ipv4 default_ipv6 interfaces],
      "hardware" => %w[hardware devices dmi processor processor_cores processor_count iscsi nvme fibre_channel_wwn loadavg],
      "mounts"   => %w[mounts],
    }

    # The families "min" covers in this engine. Real Ansible's
    # minimal_gather_subset also includes 'local' (the ansible_local
    # fact_path collector), which this tracks as its own family entry so
    # `!local` can drop just the custom-facts scan without touching the
    # rest of min. "min" itself is the bookkeeping name for the six
    # always-on gatherers in gather_facts.
    MIN_FAMILIES = %w[min local]

    ALL_FAMILIES           = MIN_FAMILIES + FAMILY_SUBSETS.keys
    DEFAULT_GATHER_TIMEOUT = 10
    DEFAULT_FACT_PATH      = "/etc/ansible/facts.d"

    # Real Ansible's get_collector_names (module_utils/facts/collector.py),
    # narrowed to the families this engine implements: 'min' is prepended
    # unconditionally, "min"/"all" (and their negations) are special, a
    # positive unknown token FAILS (BadSubsetError, mirroring real
    # Ansible's TypeError), a negated unknown token is ignored, and an
    # empty resolution widens to everything. Later tokens win. Returns
    # the set of families to gather.
    def resolve_enabled_families(tokens : Array(String)) : Set(String)
      # Real get_collector_names: `gather_subset = gather_subset or
      # ['all']` - an EMPTY list means all (Python falsy), matching the
      # argument-spec default.
      tokens = ["all"] if tokens.empty?
      all_families = Set.new(ALL_FAMILIES)
      min_only = Set.new(MIN_FAMILIES)

      additional = Set(String).new
      exclude = Set(String).new
      explicit = Set(String).new

      (["min"] + tokens).each do |token|
        case token
        when "min"
          additional += min_only
        when "all"
          additional += all_families
        when "!min"
          exclude += min_only
        when "!all"
          exclude += (all_families - min_only)
        else
          if token.starts_with?('!')
            name = token[1..]
            # Asking to exclude an unknown subset is ignored (real
            # behavior); known ones exclude their whole alias family.
            FAMILY_SUBSETS.each do |family, names|
              exclude << family if names.includes?(name)
            end
            exclude << "local" if name == "local"
          else
            unless VALID_SUBSETS.includes?(token)
              raise BadSubsetError.new("Bad subset '#{token}' given to Ansible. gather_subset options allowed: all, #{VALID_SUBSETS.join(", ")}")
            end
            FAMILY_SUBSETS.each do |family, names|
              if names.includes?(token)
                additional << family
                explicit << family
              end
            end
          end
        end
      end

      additional += all_families if additional.empty?
      additional -= (exclude - explicit)
      additional
    end

    # Gather all system facts
    # `gather_subset:` - which families of facts to collect. Tokens are
    # real Ansible's: all, min, hardware, network, mounts, the per-fact
    # aliases under FAMILY_SUBSETS, plus a leading "!" to subtract.
    # Later tokens win, unknown positive tokens fail (BadSubsetError),
    # and "min" is the floor exactly as in real Ansible - which means
    # `!all` still yields the min set, while `!all,!min` (or a bare
    # `!min`) yields nothing but the gather_subset/module_setup meta
    # keys, live-verified against 2.19.4.
    #
    # Subsetting exists to skip the EXPENSIVE families: `!hardware` avoids
    # reading every block device, `!mounts` avoids statting every mount.
    def gather_facts(subset : Array(String) = [] of String, remote_connection : Bool = false, gather_timeout : Int64? = nil, fact_path : String? = DEFAULT_FACT_PATH) : FactSet
      # No tokens at all means real Ansible's argument-spec default
      # gather_subset=["all"], not a bare "min" resolution.
      subset = ["all"] if subset.empty?
      families = resolve_enabled_families(subset)

      facts = FactSet.new

      # The minimal set, always gathered unless "min" itself was excluded
      # (!min / !all,!min) - hostname, OS/distribution, the interpreter,
      # the user, the clock and the environment. This is what real
      # Ansible's "min" subset covers.
      if families.includes?("min")
        gather_hostname(facts)
        gather_os_facts(facts)
        gather_python_facts(facts, remote_connection)
        gather_user_facts(facts)
        gather_date_time_facts(facts)
        gather_environment_facts(facts)
      end

      # ansible_local - custom *.fact files under fact_path. Part of real
      # Ansible's minimal subset ('local'); dropped only by !local or
      # !min.
      if families.includes?("local")
        facts["ansible_local"] = gather_local_facts(fact_path)
      end

      # network is NOT timeout-guarded in real Ansible either - its
      # collector takes no gather_timeout (only hardware/mounts do, via
      # module_utils/facts/hardware/linux.py's GATHER_TIMEOUT reads and
      # timeout decorator), so neither does this.
      gather_network_facts(facts) if families.includes?("network")
      gather_family_timed(facts, "hardware", gather_timeout) { |scratch| gather_hardware_facts(scratch) } if families.includes?("hardware")
      gather_family_timed(facts, "mounts", gather_timeout) { |scratch| gather_mount_facts(scratch) } if families.includes?("mounts")

      facts
    end

    # gather_timeout for the families real Ansible guards: the family
    # collects into a scratch hash inside its own fiber, and a result
    # that doesn't land within *gather_timeout* seconds (real default:
    # 10, module_utils/facts/timeout.py's DEFAULT_GATHER_TIMEOUT) is
    # dropped with a warning instead of failing the module - exactly
    # real LinuxHardware's "No mount facts were gathered due to
    # timeout." warning path. An overrun fiber cannot be killed in
    # Crystal, so it keeps filling the scratch hash nobody reads.
    private def gather_family_timed(facts : FactSet, family : String, gather_timeout : Int64?, &block : FactSet -> Nil) : Nil
      scratch = FactSet.new
      done = Channel(Bool).new
      error = nil

      spawn do
        begin
          block.call(scratch)
          done.send(true)
        rescue ex
          error = ex
          done.send(false)
        end
      end

      timed_out = select
      when done.receive
        false
      when timeout((gather_timeout || DEFAULT_GATHER_TIMEOUT).seconds)
        true
      end

      if timed_out
        STDERR.puts " [WARNING]: No #{family} facts were gathered due to timeout."
      else
        raise error.as(Exception) unless error.nil?
        facts.merge!(scratch)
      end
    end

    # Gather hostname facts
    def gather_hostname(facts)
      hostname = System.hostname
      facts["ansible_hostname"] = hostname
      facts["ansible_nodename"] = hostname

      # `hostname -f` fails outright ("Name or service not known", empty
      # stdout) on a host with no real FQDN/domain configured - common
      # on a minimal Kata/container image with no DNS setup at all.
      # Real Ansible gathers this via Python's `socket.getfqdn()`,
      # which NEVER fails/returns empty - with no resolvable FQDN it
      # falls back to plain `gethostname()`'s own result instead,
      # matching the same fallback `hostname -f`'s own shell manpage
      # documents but this engine wasn't replicating. Without it,
      # `ansible_fqdn` was silently never set at all on such hosts -
      # found via imntreal.smallstep_ca's own `Initialize CA` task,
      # which references `{{ ansible_fqdn }}` directly and failed
      # "'ansible_fqdn' is undefined" outright instead of getting the
      # same plain-hostname fallback real Ansible gives it.
      fqdn = capture("hostname", ["-f"])
      fqdn = hostname if fqdn.empty?
      facts["ansible_fqdn"] = fqdn unless fqdn.empty?

      # Real Ansible's own domain computation - Python's
      # `'.'.join(fqdn.split('.')[1:])` - ALWAYS sets a value, defaulting
      # to the empty string when the fqdn has no dot at all (exactly the
      # dotless-fallback case just above); it never leaves ansible_domain
      # completely undefined. The prior `if fqdn.includes?(".")` guard
      # here skipped setting it AT ALL in that case, so a role directly
      # referencing `{{ ansible_domain }}` (imntreal.smallstep_ca's own
      # `Initialize CA` task, one line past the ansible_fqdn fix above)
      # still failed "'ansible_domain' is undefined" instead of getting
      # real Ansible's own empty-string default.
      domain = fqdn.includes?(".") ? fqdn.sub(/^#{Regex.escape(hostname)}\./, "") : ""
      facts["ansible_domain"] = domain
    end

    # Gather OS facts
    def gather_os_facts(facts)
      os_info = parse_os_release

      if os_info
        if id = os_info["ID"]?
          distribution = case id
                         when "ubuntu"    then "Ubuntu"
                         when "debian"    then "Debian"
                         when /centos/    then "CentOS"
                         when /rhel/      then "RedHat"
                         when "fedora"    then "Fedora"
                         when "rocky"     then "Rocky"
                         when "almalinux" then "AlmaLinux"
                         else                  id.capitalize
                         end
          facts["ansible_distribution"] = distribution

          # OS family. A DERIVATIVE distro (Linux Mint, Pop!_OS, Amazon
          # Linux, ...) is not in the list above, and falling through to
          # "Linux" is wrong: real Ansible reports the family of the distro
          # it derives from, which /etc/os-release states in ID_LIKE.
          # Verified on LMDE 7 (ID=linuxmint, ID_LIKE=debian): real Ansible
          # says Debian, this said "Linux" - so every
          # `when: ansible_os_family == "Debian"` gate in every role
          # silently skipped, and an OS-keyed `vars-{{ ansible_os_family
          # }}.yml` looked for a file that does not exist. The benchmark
          # hosts have always been plain Ubuntu/Rocky, which is why no round
          # ever caught this.
          os_family = Krikri::PluginHelpers::DistributionFacts.family_for(distribution)
          if os_family.nil?
            os_info["ID_LIKE"]?.try do |id_like|
              id_like.split(/\s+/).each do |like|
                os_family ||= Krikri::PluginHelpers::DistributionFacts.family_for(like.capitalize)
              end
            end
          end
          facts["ansible_os_family"] = os_family || distribution
        end

        if version = os_info["VERSION_ID"]?
          facts["ansible_distribution_version"] = version
          major = version.split(".").first
          facts["ansible_distribution_major_version"] = major
        end

        # Real Ansible's DistributionFactCollector always sets this fact,
        # falling back to "" when the OS has no release codename at all
        # (RHEL-family /etc/os-release ships no VERSION_CODENAME, unlike
        # Ubuntu/Debian) - never leaves it genuinely undefined. Previously
        # this key was skipped entirely on RHEL-family hosts, so any
        # templated reference (e.g. a `with_first_found:` candidate like
        # "{{ ansible_distribution | lower }}/{{ ansible_distribution_
        # release }}.yml") raised "'ansible_distribution_release' is
        # undefined" instead of just rendering an empty path segment that
        # (correctly) fails to match any file and falls through to the next
        # candidate. Found benchmarking weareinteractive.openssl (round
        # 179) on Rocky 9.6.
        facts["ansible_distribution_release"] = os_info["VERSION_CODENAME"]? || ""

        # Real Ansible computes the generic distro/version/release facts
        # first and then lets the matching distribution-FILE parser override
        # them - the order matters, since several of those branches set a
        # release/version of their own that must win over the os-release
        # values just written above. Only the Debian-family parser is ported
        # (see PluginHelpers::DistributionFacts): it is where every
        # derivative display name lives, and the RedHat/SUSE names this
        # engine already emits from ID were verified to match real Ansible
        # as-is.
        if raw = os_release_content
          if overrides = Krikri::PluginHelpers::DistributionFacts.refine_debian(raw)
            overrides.each { |key, value| facts[key] = value }
            if refined = overrides["ansible_distribution"]?
              facts["ansible_os_family"] = Krikri::PluginHelpers::DistributionFacts.family_for(refined) || facts["ansible_os_family"]
            end
          end
        end

        # Real Ansible's distribution-FILE facts (see
        # DistributionFacts.distribution_file_facts for the ported walk). Found
        # missing via cloudalchemy.process_exporter (round 195): its
        # with_first_found vars list keys off
        # `{{ ansible_distribution_file_variety | lower }}.yml` → redhat.yml on
        # Rocky; with the keys never set here the template raised
        # "'ansible_distribution_file_variety' is undefined" and the task
        # failed where real Ansible rc=0'd. The parse's own distribution
        # override is the real-Ansible quirk where ansible_distribution on
        # Rocky comes from /etc/redhat-release's first token ("Rocky"), not
        # the os-release ID - os_family re-derivation follows it, falling back
        # to ID_LIKE for names family_for doesn't know (e.g. "Rocky Linux"
        # from an NA-entry parse) exactly like real Ansible's own order.
        if file_facts = Krikri::PluginHelpers::DistributionFacts.distribution_file_facts(os_info["ID"]? || "")
          file_facts.each { |key, value| facts[key] = value }
          if refined = file_facts["distribution"]?
            facts["ansible_distribution"] = refined
            new_family = Krikri::PluginHelpers::DistributionFacts.family_for(refined)
            if new_family.nil?
              os_info["ID_LIKE"]?.try do |id_like|
                id_like.split(/\s+/).each do |like|
                  new_family ||= Krikri::PluginHelpers::DistributionFacts.family_for(like.capitalize)
                end
              end
            end
            facts["ansible_os_family"] = new_family if new_family
          end
        end
      end

      # ansible_lsb - real Ansible's LSBFactCollector (via `lsb_release`, or a
      # parse of /etc/lsb-release when the command is absent). Only Ubuntu
      # ships /etc/lsb-release by default among the distros this project
      # targets - entirely unimplemented before, so `ansible_facts['lsb']`
      # was always undefined and any dotted access on it (`.codename`, etc.)
      # rendered as an empty string rather than raising. Found benchmarking
      # buluma.fish's own Ubuntu apt-repo task (`{{ ansible_facts['lsb'].
      # codename | lower }}` in the PPA's `deb` line): the empty codename
      # left a malformed sources.list entry ("Malformed entry ... (Component)"),
      # crashing `apt-get update` outright on a role real Ansible installs
      # cleanly.
      # Real Ansible's LSBFactCollector unconditionally sets
      # `facts_dict['lsb'] = lsb_facts` at the end of `collect()`
      # (facts/system/lsb.py) even when lsb_facts stayed `{}` (no
      # `lsb_release` binary AND no /etc/lsb-release) - `ansible_facts
      # ['lsb']` is always a defined (possibly empty) dict, never an
      # absent key. This previously only set the fact when /etc/lsb-
      # release existed, so `ansible_facts['lsb'] is defined` was False
      # on distros without it (Debian without lsb-release installed) -
      # real Ansible evaluates the same `is defined` as True there and
      # moves on to the next `when:` clause. Found benchmarking
      # githubixx.ansible_role_wireguard's own "Setup for Raspbian" task
      # (`when: ansible_facts['lsb'] is defined and ansible_facts['lsb']
      # ['id'] == "Raspbian"`) - real ansible-playbook actually hard-
      # fails evaluating the second clause ('dict' object has no
      # attribute 'id', since lsb_facts has no 'id' key at all on
      # Debian), krikri silently skipped instead.
      lsb_info = {} of String => String
      if File.exists?("/etc/lsb-release")
        File.each_line("/etc/lsb-release") do |line|
          key, sep, value = line.partition('=')
          next if sep.empty?
          lsb_info[key.strip] = value.strip.strip('"')
        end
      end
      lsb_facts = {} of String => String
      lsb_facts["id"] = lsb_info["DISTRIB_ID"] if lsb_info["DISTRIB_ID"]?
      lsb_facts["description"] = lsb_info["DISTRIB_DESCRIPTION"] if lsb_info["DISTRIB_DESCRIPTION"]?
      lsb_facts["release"] = lsb_info["DISTRIB_RELEASE"] if lsb_info["DISTRIB_RELEASE"]?
      lsb_facts["codename"] = lsb_info["DISTRIB_CODENAME"] if lsb_info["DISTRIB_CODENAME"]?
      facts["ansible_lsb"] = lsb_facts

      facts["ansible_pkg_mgr"] = detect_pkg_mgr

      facts["ansible_system"] = "Linux"

      # ansible_machine_id - real Ansible reads /etc/machine-id (falling back to
      # /var/lib/dbus/machine-id) and strips the trailing newline. Roles gate
      # re-gather guards on its presence (linux-system-roles/journald's `when:
      # __journald_required_facts | difference(ansible_facts.keys() | list) |
      # length > 0`, where machine_id is one of the required facts) - omitting
      # it entirely made that guard never see all required facts as already
      # gathered, so the guarded setup: task ran on every play instead of being
      # skipped.
      machine_id = ["/etc/machine-id", "/var/lib/dbus/machine-id"].compact_map do |path|
        File.exists?(path) ? File.read(path).strip : nil
      end.find { |contents| !contents.empty? }
      facts["ansible_machine_id"] = machine_id if machine_id

      # service_mgr - which init system is PID 1. Real Ansible reports this
      # separately from os_family, and modern roles gate systemd-only tasks on
      # it (dev-sec os_hardening's ctrl-alt-del + coredump tasks all do).
      # systemd is detectable by its /run/systemd/system marker (present when
      # systemd is PID 1, absent under sysvinit/upstart/openrc even if the
      # systemctl binary exists).
      if Dir.exists?("/run/systemd/system")
        facts["ansible_service_mgr"] = "systemd"

        # ansible_systemd.version / .features - real Ansible parses these from
        # `systemctl --version`'s two lines (version number on line 1, feature
        # flags on line 2+). Roles gate systemd-feature-specific config on the
        # version (dev-sec's ssh_hardening and konstruktoid's resolved.conf.j2
        # both do `ansible_facts.systemd.version | int >= N`).
        version_output = capture("systemctl", ["--version"])
        unless version_output.empty?
          lines = version_output.lines
          if first_line = lines[0]?
            if version = first_line.split(" ")[1]?
              systemd_facts = {} of String => String
              systemd_facts["version"] = version
              systemd_facts["features"] = lines[1..].join(" ").strip
              facts["ansible_systemd"] = systemd_facts
            end
          end
        end
      elsif Dir.exists?("/etc/openrc")
        facts["ansible_service_mgr"] = "openrc"
      elsif File.exists?("/sbin/upstart") || Dir.exists?("/etc/init")
        facts["ansible_service_mgr"] = "upstart"
      else
        facts["ansible_service_mgr"] = "sysvinit"
      end

      # virtualization_type - whether we're inside a container/VM, which roles
      # use to skip kernel-module and sysctl work that can't apply there
      # (os_hardening's modprobe/sysctl tasks do exactly this).
      facts["ansible_virtualization_type"] = detect_virtualization

      # virtualization_role ("guest"/"host"/"NA") - entirely missing
      # before this, found benchmarking Ansible-Security-Compliance's
      # rhel7-role-hipaa (round823): its own audit-rule tasks gate on
      # `ansible_virtualization_role != "guest" or ansible_virtualization_
      # type != "docker"` (skip certain host-only audit rules on a
      # container/VM guest) - real Ansible resolves this fine on a real
      # cloud VM (role: "guest"), this engine raised "Error while
      # evaluating conditional: 'ansible_virtualization_role' is
      # undefined" and crashed the whole run outright instead of just
      # this one task's when:. This engine's own #detect_virtualization
      # never distinguishes hypervisor-host detection from guest
      # detection (real Ansible's own host-side checks - a populated
      # /etc/xen/, a running libvirtd, etc - are rare in practice and not
      # implemented here), so "host" is never reported; every detected
      # type maps to "guest", matching the overwhelming common case (a
      # real role's target is virtualized, not the hypervisor itself).
      facts["ansible_virtualization_role"] = facts["ansible_virtualization_type"] == "None" ? "NA" : "guest"

      # system_vendor - real Ansible's DMI fact collector reads this straight
      # from /sys/class/dmi/id/sys_vendor (falling back to "NA" when the file
      # is missing/unreadable, e.g. inside some container runtimes). Entirely
      # missing before - sbaerlocher.qemu-guest-agent/.ovirt-guest-agent's own
      # `when: ansible_system_vendor == 'QEMU'` guard raised "Error while
      # evaluating conditional: 'ansible_system_vendor' is undefined" instead
      # of just evaluating (usually to false, correctly skipping the task) -
      # found on a Kata/cloud-hypervisor guest, where the real value doesn't
      # even match 'QEMU'.
      sys_vendor = capture("cat", ["/sys/class/dmi/id/sys_vendor"]).strip
      facts["ansible_system_vendor"] = sys_vendor.empty? ? "NA" : sys_vendor

      # product_version - same DMI class as system_vendor above, read from
      # /sys/class/dmi/id/product_version, "NA" fallback matching real
      # Ansible's own DMI fact collector exactly. Entirely missing before -
      # found benchmarking robertdebock.bios_update: the role's own
      # rescue: block references `ansible_product_version` in a debug:
      # msg, which real Ansible resolves (even to a virtualized "NA"-ish
      # placeholder like "pc-q35-...", but resolves) while this engine
      # raised "'ansible_product_version' is undefined" instead - ironic,
      # since that's the exact strict-undefined behavior round 161 added
      # on purpose for module-arg rendering, just tripped by a fact this
      # engine never gathered rather than the role's own genuine bug.
      product_version = capture("cat", ["/sys/class/dmi/id/product_version"]).strip
      facts["ansible_product_version"] = product_version.empty? ? "NA" : product_version

      # apparmor.status - real Ansible's own ApparmorFactCollector just
      # checks for /sys/kernel/security/apparmor's existence (not whether any
      # profile is actually enforcing) - "enabled" if present, "disabled"
      # otherwise, matched exactly (ansible/module_utils/facts/system/
      # apparmor.py). Entirely missing before: found via robertdebock.vault's
      # own `when: ansible_apparmor.status == "enabled"` guard on its
      # `aa-enforce` hardening task, which real Ansible ran (real host has
      # AppArmor active) and this engine always silently skipped instead,
      # since the undefined fact made the `when:` false regardless of the
      # host's real AppArmor state.
      apparmor_facts = {} of String => String
      apparmor_facts["status"] = Dir.exists?("/sys/kernel/security/apparmor") ? "enabled" : "disabled"
      facts["ansible_apparmor"] = apparmor_facts

      # ansible_fips - real Ansible's FipsFactCollector (module_utils/
      # facts/system/fips.py) ALWAYS populates this, as a genuine
      # boolean: true only when /proc/sys/crypto/fips_enabled reads
      # exactly "1", false otherwise (file missing, unreadable, any
      # other content). Entirely missing before - found via
      # geerlingguy.postgresql on Rocky 9.6 (round 65000+): the role's
      # own `postgresql_auth_method: "{{ ansible_fips |
      # ternary('scram-sha-256', 'md5') }}"` flows into the pg_hba.conf
      # template's `{{ client.auth_method }}`, and with the fact
      # undefined the ternary rendered the literal text "undefined"
      # into every host line - postgresql.service then refused to start
      # ('invalid authentication method "undefined"') after a perfectly
      # successful initdb, while real Ansible's run of the identical
      # role succeeded end to end. A JSON bool, not the "False"-string
      # shape some other facts use here: a string "False" is truthy
      # under Jinja2 semantics and ternary would then pick the FIPS
      # branch on every host.
      facts["ansible_fips"] = capture("cat", ["/proc/sys/crypto/fips_enabled"]).strip == "1"

      # ansible_selinux.status - real Ansible's SelinuxFactCollector (module_
      # utils/facts/system/selinux.py) reports 'Missing selinux Python
      # library' when the target has no selinux Python bindings at all
      # (stock Debian/Ubuntu), or 'disabled'/'enabled' (+ mode/config_mode/
      # type/policyvers when enabled) otherwise. Entirely missing before -
      # `ansible_selinux.status is defined` (robertdebock.selinux's own gate
      # on its "Manage selinux"/"Manage selinux booleans" tasks, and a common
      # real-role idiom generally) always evaluated false regardless of the
      # host's real SELinux state, silently skipping SELinux management even
      # on a real RHEL-family SELinux host - found live on a Rocky 9.6
      # target. Uses `getenforce`/reads /etc/selinux/config directly (this
      # plugin already shells out via #capture rather than binding libselinux
      # itself, matching the rest of this file's own approach) instead of a
      # Python-library check, since presence of the `getenforce` binary
      # itself is the same practical signal on any real target.
      selinux_facts = {} of String => String
      getenforce_bin = capture("which", ["getenforce"])
      if getenforce_bin.empty?
        selinux_facts["status"] = "Missing selinux Python library"
      else
        runtime_mode = capture("getenforce").downcase
        if runtime_mode == "disabled"
          selinux_facts["status"] = "disabled"
        else
          selinux_facts["status"] = "enabled"
          selinux_facts["mode"] = runtime_mode
          selinux_facts["policyvers"] = "unknown"
          config_mode = "unknown"
          config_type = "unknown"
          if File.exists?("/etc/selinux/config")
            File.read("/etc/selinux/config").each_line do |line|
              stripped = line.strip
              next if stripped.empty? || stripped.starts_with?("#")
              if stripped.starts_with?("SELINUX=")
                config_mode = stripped.split("=", 2)[1].strip
              elsif stripped.starts_with?("SELINUXTYPE=")
                config_type = stripped.split("=", 2)[1].strip
              end
            end
          end
          selinux_facts["config_mode"] = config_mode
          selinux_facts["type"] = config_type
        end
      end
      facts["ansible_selinux"] = selinux_facts
      facts["ansible_selinux_python_present"] = getenforce_bin.empty? ? "False" : "True"

      utsname = uninitialized LibC::Utsname
      uname_ok = LibC.uname(pointerof(utsname)) == 0

      kernel = uname_ok ? String.new(utsname.release.to_unsafe).strip : ""
      facts["ansible_kernel"] = kernel unless kernel.empty?
      facts["ansible_kernel_version"] = kernel unless kernel.empty?

      arch = uname_ok ? String.new(utsname.machine.to_unsafe).strip : ""
      facts["ansible_machine"] = arch unless arch.empty?
      facts["ansible_architecture"] = arch unless arch.empty?

      # dpkg/rpm give a distro-specific userspace arch name (e.g. "amd64" vs
      # "x86_64") that can't be derived from uname alone, so this still shells
      # out - but without the extra `/bin/sh -c` layer, and falling back to the
      # already-computed `arch` above instead of forking `uname -m` again.
      userspace = capture("dpkg", ["--print-architecture"])
      userspace = capture("rpm", ["--eval", "%{_arch}"]) if userspace.empty?
      userspace = arch if userspace.empty?
      facts["ansible_userspace_architecture"] = userspace unless userspace.empty?

      # ansible_userspace_bits ("64" / "32") - real Ansible derives this from
      # getconf LONG_BIT (found via gantsign.ansible-role-golang's
      # vars/architecture/{{ ansible_facts.architecture }}-{{ userspace_bits }}.yml
      # include chain, which real Ansible resolves and krikri-playbook didn't).
      long_bits = capture("getconf", ["LONG_BIT"])
      long_bits = "64" if long_bits.empty? && arch =~ /64/
      long_bits = "32" if long_bits.empty? && !arch.empty?
      facts["ansible_userspace_bits"] = long_bits unless long_bits.empty?
    end

    # Detect whether we're running inside a container/VM, following the same
    # heuristics real Ansible's fact gathering uses. Returns the virtualization
    # type name (e.g. "docker", "lxc", "kvm", "xen"), or "None" (the exact
    # string real Ansible uses) when running on bare metal / a plain host.
    # ansible_pkg_mgr / ansible_facts.pkg_mgr - which package manager real
    # Ansible's own pkg_mgr.py fact module reports, entirely unset before this
    # (found via openstack.ansible-hardening's own `include_tasks: "{{
    # ansible_facts['pkg_mgr'] }}.yml"` - the role's main OS-dispatch point,
    # resolving to the literal "undefined.yml" and failing the include
    # outright, taking the rest of that STIG control file's tasks down with
    # it). Real Ansible's own detection checks a longer, more exhaustive list
    # of package-manager binary paths and has extra dnf-vs-yum-symlink
    # disambiguation; this covers the package managers real roles actually
    # gate on (apt/dnf/yum/zypper/pacman/apk/pkgng), checked in the same
    # dnf-before-yum priority real Ansible uses so a modern RHEL system
    # (where /usr/bin/yum is often just a symlink to dnf) reports "dnf".
    def detect_pkg_mgr : String
      candidates = {
        "/usr/bin/dnf"     => "dnf",
        "/usr/bin/yum"     => "yum",
        "/usr/bin/apt-get" => "apt",
        "/usr/bin/zypper"  => "zypper",
        "/usr/bin/pacman"  => "pacman",
        "/sbin/apk"        => "apk",
        "/usr/sbin/pkg"    => "pkgng",
      }
      candidates.find { |path, _| File.exists?(path) }.try(&.[1]) || "unknown"
    end

    def detect_virtualization : String
      # Container markers first - the cheapest, most unambiguous signals.
      return "docker" if File.exists?("/.dockerenv") || File.exists?("/.dockerinit")
      return "lxc" if File.exists?("/var/lib/lxc")

      begin
        if File.exists?("/proc/1/cgroup")
          # systemd containers expose the container type in the cgroup list;
          # cgroup v1 names each container subsystem after the type (docker,
          # lxc), cgroup v2 keeps the last component name too. Look for the
          # well-known ones.
          cgroup = File.read("/proc/1/cgroup")
          return "docker" if cgroup.includes?("docker")
          return "lxc" if cgroup.includes?("lxc")
          return "openvz" if cgroup.includes?("openvz")
        end
      rescue
        # Ignore read failures; fall through to the sysfs/command probes.
      end

      # PID 1's own `container=` environment variable - real Ansible's
      # `LinuxVirtual#get_virtual_facts` checks this (module_utils/facts/
      # virtual/linux.py) BEFORE falling back to `systemd-detect-virt`,
      # and it is what actually makes podman detection reliable: podman
      # (and systemd-nspawn, and older LXC) sets this unconditionally,
      # with no dependency on the `systemd-detect-virt` binary being
      # installed at all - found live confirming the round-303 dict-
      # iteration fix via `jtyr.motd`: a minimal podman container with
      # no systemd package installed has neither `systemd-detect-virt`
      # nor `/run/systemd/container`, so the two checks below this one
      # both fell through to "None" while real ansible-playbook (whose
      # primary signal is this env var, not the external binary)
      # correctly reported "podman"/"guest". `/proc/1/environ` is
      # NUL-separated, not newline-separated, and reading it needs root
      # (same requirement real Ansible's own comment notes).
      begin
        if File.exists?("/proc/1/environ")
          if virt = parse_container_env(File.read("/proc/1/environ"))
            return virt
          end
        end
      rescue
        # Permission denied (non-root) or unreadable - fall through to
        # the systemd/DMI probes below, same as the cgroup check above.
      end

      # systemd-detect-virt is authoritative for systemd hosts; the alternatives
      # below cover the non-systemd cases.
      sv = capture("systemd-detect-virt")
      case sv
      when "kvm", "qemu", "xen", "vmware", "oracle", "microsoft", "amazon", "zvm", "powervm", "parallels", "bhyve", "uml", "docker", "lxc", "openvz", "podman", "wsl"
        return sv
      when "none"
        return "None"
      end

      # Non-systemd fallbacks: the DMI chassis type for VMs, and /proc/self for
      # a few container runtimes that don't leave the markers above.
      dmi = capture("cat", ["/sys/class/dmi/id/product_name"])
      if dmi.includes?("KVM") || dmi.includes?("QEMU")
        return "kvm"
      elsif dmi.includes?("VMware")
        return "vmware"
      elsif dmi.includes?("VirtualBox")
        return "virtualbox"
      end

      "None"
    end

    # Parses PID 1's `/proc/1/environ` content (NUL-separated key=value
    # entries) for a `container=` marker, matching real Ansible's own
    # `container=lxc`/`container=podman`/generic-`container=.` priority
    # order (module_utils/facts/virtual/linux.py). Only `lxc` and
    # `podman` get their own specific virtualization_type - EVERY other
    # non-empty value (docker, oci, systemd-nspawn, ...) normalizes to
    # the literal string "container", never the raw env value itself
    # (`if re.search('^container=.', line): virtual_facts
    # ['virtualization_type'] = 'container'` - it does not capture or
    # reuse the matched value). Previously this returned the raw value
    # verbatim, so a Kata VM whose guest happened to carry `container=
    # docker` in PID 1's environ (a leftover from the base rootfs image
    # having been built via `podman build`/Containerfile, even though
    # Kata boots a real guest kernel with no actual container runtime
    # inside it) reported "docker" - matching a role's `virtualization_
    # type == "docker"` when: check that real Ansible (which reports
    # the generic "container") correctly left false. Found benchmarking
    # juju4.auditd's own "Not in container" block guard. Pulled out of
    # #detect_virtualization as a pure function so it's testable without
    # real `/proc` access. Returns nil when no `container=` entry is
    # present at all (the plain-host case).
    def parse_container_env(environ : String) : String?
      entries = environ.split('\0')
      return "lxc" if entries.any? { |e| e == "container=lxc" }
      return "podman" if entries.any? { |e| e == "container=podman" }

      entry = entries.find(&.starts_with?("container="))
      return nil unless entry
      value = entry.split('=', 2)[1]?
      value.nil? || value.empty? ? nil : "container"
    end

    # The RAW text of whichever os-release file #parse_os_release used - real
    # Ansible's distribution-file parsers match substrings against the whole
    # file, not against parsed key/value pairs (`"Mint" in data`), so a
    # faithful port needs the original text.
    def os_release_content : String?
      ["/etc/os-release", "/usr/lib/os-release"].each do |path|
        next unless File.exists?(path)
        content = File.read(path)
        return content unless content.strip.empty?
      end
      nil
    end

    def parse_os_release : Hash(String, String)?
      info = {} of String => String

      ["/etc/os-release", "/usr/lib/os-release"].each do |path|
        next unless File.exists?(path)

        File.read_lines(path).each do |line|
          line = line.strip
          next if line.empty? || line.starts_with?("#")
          next unless line.includes?("=")

          key, value = line.split("=", 2)
          value = value.gsub(/^["']|["']$/, "")
          info[key] = value
        end

        return info unless info.empty?
      end

      nil
    end

    def gather_network_facts(facts)
      # `ip -4 route get 1` prints one line shaped like
      # "1.0.0.0 via 192.168.1.1 dev eth0 src 192.168.1.50 uid 0" - $3 is the
      # gateway (only present when the route actually has a "via" hop), $7
      # the source address (this host's own IP on the default route), $5 the
      # outbound interface name. Real Ansible's `ansible_default_ipv4` fact
      # includes all three (plus more fields this doesn't bother gathering) -
      # `interface` specifically is what konstruktoid-hardening's
      # sysctl.ipv6.conf.j2 template reads (`ansible_facts.default_ipv4.
      # interface`) to scope an IPv6 sysctl key to the default route's own
      # interface. Omitting it left that lookup undefined, which the
      # `regex_replace` filter downstream can't operate on - failing the
      # whole template render. `gateway` was missing entirely (not just
      # incomplete) until found benchmarking buluma.checkmk_agent's own
      # `when: ansible_facts['default_ipv4'].gateway is defined` - real
      # Ansible's `is defined` check was true (every routable host has a
      # default gateway), crystal's was always false since the key never
      # existed, so the gated debug task was silently skipped instead of
      # run.
      default_route = `ip -4 route get 1 2>/dev/null | head -1`.strip
      route_fields = default_route.split(/\s+/)
      ipv4 = route_fields[6]?.to_s
      interface = route_fields[4]?.to_s
      gateway = route_fields[1]? == "via" ? route_fields[2]?.to_s : ""
      if !ipv4.empty?
        default_ipv4 = {"address" => ipv4}
        default_ipv4["interface"] = interface unless interface.empty?
        default_ipv4["gateway"] = gateway unless gateway.empty?
        facts["ansible_default_ipv4"] = default_ipv4
      end

      all_ipv4 = `ip -4 addr show 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1`.strip
      unless all_ipv4.empty?
        addresses = all_ipv4.split("\n").map(&.strip).reject(&.empty?)
        facts["ansible_all_ipv4_addresses"] = addresses
      end

      # ansible_interfaces - a flat list of every network interface NAME
      # (not addresses) real Ansible's own LinuxNetwork fact module
      # always sets. Entirely missing before this, found benchmarking
      # brianshumate.consul: its own "Check specified ethernet
      # interface" task does `when: consul_iface in ansible_interfaces`
      # - with the fact undefined, the when: raised "Error while
      # evaluating conditional: 'ansible_interfaces' is undefined" and
      # crashed the whole run outright instead of just evaluating the
      # membership test. `/sys/class/net` lists exactly the interface
      # names real Ansible's own netifaces-based collection reports.
      if Dir.exists?("/sys/class/net")
        interfaces = Dir.children("/sys/class/net").sort
        facts["ansible_interfaces"] = interfaces

        # Per-interface facts - real Ansible's own LinuxNetwork collector
        # reports every interface BOTH as `ansible_interfaces` entries and
        # as a top-level `ansible_<iface>` dict (ansible_eth0, ansible_ens3,
        # ...) carrying device/type/mtu/macaddress/ipv4/ipv6. Real Ansible
        # then flattens those into the variable namespace
        # (inject_facts_as_vars), which is what makes the dynamic
        # per-interface idiom work: ricsanfre.dnsmasq's own
        # `vars['ansible_' + dnsmasq_interface].ipv4.address` resolves
        # through the `vars` magic dict - which krikri's build_vars_context
        # populates from the same flat fact keys - so all that was missing
        # was the facts themselves: the `vars[...]` lookup failed with
        # "object of type 'dict' has no attribute 'ansible_eth0'" because
        # no such key was ever gathered, round 214.
        interfaces.each do |iface|
          interface_facts = gather_interface_facts(iface, interface, gateway)
          facts["ansible_#{iface}"] = interface_facts
        end
      end
    end

    # One interface's `ansible_<iface>` dict - a subset of real Ansible's
    # LinuxNetwork collector's shape (device/type/mtu/macaddress/ipv4/
    # ipv4_secondaries/ipv6), built from sysfs plus `ip -o addr show`.
    # ipv4 carries gateway only on the interface holding the default
    # route, matching real Ansible's output there.
    private def gather_interface_facts(iface : String, default_interface : String, default_gateway : String) : Hash(String, JSON::Any)
      iface_facts = {} of String => JSON::Any
      iface_facts["device"] = JSON::Any.new(iface)
      iface_facts["type"] = JSON::Any.new(iface == "lo" ? "loopback" : "ether")

      if mtu = read_trimmed("/sys/class/net/#{iface}/mtu")
        iface_facts["mtu"] = JSON::Any.new(mtu.to_i64)
      end

      mac = read_trimmed("/sys/class/net/#{iface}/address")
      if mac && !mac.empty? && mac != "00:00:00:00:00:00"
        iface_facts["macaddress"] = JSON::Any.new(mac)
      end

      ipv4 = nil
      secondaries = [] of JSON::Any
      capture("ip", ["-o", "-4", "addr", "show", "dev", iface]).each_line do |line|
        fields = line.split(/\s+/)
        addr_prefix = fields[3]?
        next unless fields[2]? == "inet" && addr_prefix

        address, prefix = addr_prefix.split("/", 2)
        prefix_len = prefix.to_i?
        next unless prefix_len

        netmask = prefix_to_netmask(prefix_len)
        entry = {
          "address" => JSON::Any.new(address),
          "netmask" => JSON::Any.new(netmask),
          "network" => JSON::Any.new(u32_to_ipv4(ipv4_to_u32(address) & ipv4_to_u32(netmask))),
        }
        if fields[4]? == "brd" && (bcast = fields[5]?)
          entry["broadcast"] = JSON::Any.new(bcast)
        end
        if ipv4.nil?
          ipv4 = entry
        else
          secondaries << JSON::Any.new(entry)
        end
      end

      if ipv4_hash = ipv4
        if iface == default_interface && !default_gateway.empty?
          ipv4_hash["gateway"] = JSON::Any.new(default_gateway)
        end
        iface_facts["ipv4"] = JSON::Any.new(ipv4_hash)
        iface_facts["ipv4_secondaries"] = JSON::Any.new(secondaries) unless secondaries.empty?
      end

      ipv6_list = [] of JSON::Any
      capture("ip", ["-o", "-6", "addr", "show", "dev", iface]).each_line do |line|
        fields = line.split(/\s+/)
        addr_prefix = fields[3]?
        next unless fields[2]? == "inet6" && addr_prefix

        address, prefix = addr_prefix.split("/", 2)
        entry = {"address" => JSON::Any.new(address), "prefix" => JSON::Any.new(prefix)}
        if scope = fields[5]?
          entry["scope"] = JSON::Any.new(scope)
        end
        ipv6_list << JSON::Any.new(entry)
      end
      iface_facts["ipv6"] = JSON::Any.new(ipv6_list) unless ipv6_list.empty?

      iface_facts
    end

    private def read_trimmed(path : String) : String?
      File.read(path).strip
    rescue File::NotFoundError
      nil
    end

    private def prefix_to_netmask(prefix : Int32) : String
      (0..3).map do |i|
        remaining = prefix - i * 8
        byte = remaining >= 8 ? 255u8 : remaining > 0 ? ((0xFF_u32 << (8 - remaining)) & 0xFF).to_u8! : 0u8
        byte.to_s
      end.join(".")
    end

    private def ipv4_to_u32(ip : String) : UInt32
      parts = ip.split(".").map(&.to_u32)
      (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    end

    private def u32_to_ipv4(value : UInt32) : String
      [(value >> 24) & 0xFF, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF].join(".")
    end

    def gather_hardware_facts(facts)
      # Memory facts - manual parsing of /proc/meminfo
      if File.exists?("/proc/meminfo")
        meminfo = File.read("/proc/meminfo")

        if match = meminfo.match(/MemTotal:\s+(\d+)/)
          facts["ansible_memtotal_mb"] = match[1].to_i64 // 1024
        end

        if match = meminfo.match(/MemAvailable:\s+(\d+)/)
          facts["ansible_memfree_mb"] = match[1].to_i64 // 1024
        end

        if match = meminfo.match(/SwapTotal:\s+(\d+)/)
          facts["ansible_swaptotal_mb"] = match[1].to_i64 // 1024
        end

        if match = meminfo.match(/SwapFree:\s+(\d+)/)
          facts["ansible_swapfree_mb"] = match[1].to_i64 // 1024
        end

        # The namespaced `ansible_memory_mb` fact (surfaces as
        # `ansible_facts.memory_mb`), mirroring real ansible-core's Linux
        # hardware collector: real{total,used,free}, nocache{free,used},
        # swap{total,free,used,cached}, all MB (kB // 1024), computed
        # values omitted when their inputs are absent. Found via
        # geerlingguy.swap's own `when: ansible_facts.memory_mb['swap']
        # ['total'] > 0` - the legacy flat facts above existed but this
        # dict never did, so the condition died with "object of type
        # 'dict' has no attribute 'memory_mb'".
        memstats = {} of String => Int64
        meminfo.each_line do |line|
          key, _, val = line.partition(":")
          next if val.empty?
          if num = val.strip.split(" ")[0]?.try(&.to_i64?)
            memstats[key.downcase] = num // 1024
          end
        end

        mb_val = ->(k : String) { memstats[k]? ? JSON::Any.new(memstats[k]) : JSON::Any.new(nil) }

        real = {"total" => mb_val.call("memtotal"), "free" => mb_val.call("memfree")} of String => JSON::Any
        real["used"] = JSON::Any.new(memstats["memtotal"] - memstats["memfree"]) if memstats["memtotal"]? && memstats["memfree"]?

        nocache = {} of String => JSON::Any
        if (cached = memstats["cached"]?) && (free = memstats["memfree"]?) && (buffers = memstats["buffers"]?)
          nocache_free = cached + free + buffers
          nocache["free"] = JSON::Any.new(nocache_free)
          nocache["used"] = JSON::Any.new(memstats["memtotal"] - nocache_free) if memstats["memtotal"]?
        end

        swap = {"total" => mb_val.call("swaptotal"), "free" => mb_val.call("swapfree")} of String => JSON::Any
        swap["used"] = JSON::Any.new(memstats["swaptotal"] - memstats["swapfree"]) if memstats["swaptotal"]? && memstats["swapfree"]?
        swap["cached"] = mb_val.call("swapcached")

        facts["ansible_memory_mb"] = {
          "real"    => JSON::Any.new(real),
          "nocache" => JSON::Any.new(nocache),
          "swap"    => JSON::Any.new(swap),
        } of String => JSON::Any
      end

      # CPU facts
      # Use Crystal's native System.cpu_count for vcpus
      vcpus = System.cpu_count.to_i64
      facts["ansible_processor_vcpus"] = vcpus if vcpus > 0

      # For physical processors and cores per processor, still need /proc/cpuinfo
      if File.exists?("/proc/cpuinfo")
        cpuinfo = File.read("/proc/cpuinfo")

        physical_ids = cpuinfo.scan(/physical id\s+:\s+(\d+)/).map(&.[1]).uniq
        count = physical_ids.size.to_i64
        count = 1_i64 if count == 0
        facts["ansible_processor_count"] = count

        if match = cpuinfo.match(/cpu cores\s+:\s+(\d+)/)
          facts["ansible_processor_cores"] = match[1].to_i64
        end

        if match = cpuinfo.match(/model name\s+:\s+(.+)/)
          facts["ansible_processor"] = [match[1].strip]
        end
      end

      gather_device_facts(facts)
    end

    # Block-device facts - the `ansible_devices` dict (keyed by device name)
    # real ansible-core's Linux hardware collector ALWAYS populates by
    # scanning /sys/block/*. Found via Tecnativa.hetzner_rescue_installimage's
    # templates/autosetup.j2 (`{% for device in ansible_devices if
    # device.startswith("sd") ... %}`): with the fact never set, the loop died
    # with "can't iterate over undefined" and killed the role's "configure
    # installation" task, which real Ansible completes (iterating a missing
    # fact is never the case there - its setup module defines the key even as
    # an empty dict). Deliberately NOT conditioned on non-empty, unlike
    # ansible_mounts above: templates need the key to exist and be iterable
    # even when the scan finds nothing (minimal containers) - making it
    # omit-when-empty would reintroduce exactly this bug.
    def gather_device_facts(facts)
      devices = {} of String => JSON::Any

      begin
        Dir.each_child("/sys/block") do |name|
          # Real Ansible's DEVICE_EXCLUDE_PATTERNS skips loopback and ram
          # devices entirely.
          next if name.starts_with?("loop") || name.starts_with?("ram")

          sysfs = "/sys/block/#{name}"
          dev = {} of String => JSON::Any

          # Every file below may be absent (virtual/nvme devices lack
          # device/vendor, some lack queue/) - tolerate each miss rather
          # than fail the whole gather.
          if sectors = read_trimmed("#{sysfs}/size")
            dev["sectors"] = JSON::Any.new(sectors.to_i64?)
            dev["size"] = JSON::Any.new(human_block_size(sectors.to_i64? || 0_i64))
          end
          if val = read_trimmed("#{sysfs}/queue/physical_block_size")
            dev["sectorsize"] = JSON::Any.new(val.to_i64?)
          end
          if val = read_trimmed("#{sysfs}/removable")
            dev["removable"] = JSON::Any.new(val)
          end
          if val = read_trimmed("#{sysfs}/queue/rotational")
            dev["rotational"] = JSON::Any.new(val)
          end
          if val = read_trimmed("#{sysfs}/device/vendor")
            dev["vendor"] = JSON::Any.new(val)
          end
          if val = read_trimmed("#{sysfs}/device/model")
            dev["model"] = JSON::Any.new(val)
          end
          dev["virtual"] = JSON::Any.new(
            name.starts_with?("dm-") || name.starts_with?("md") || name.starts_with?("zram") ? "1" : "0")

          partitions = {} of String => JSON::Any
          Dir.each_child(sysfs) do |part_name|
            next unless part_name.starts_with?(name)
            pdir = "#{sysfs}/#{part_name}"
            next unless File.directory?(pdir)
            part = {} of String => JSON::Any
            part["name"] = JSON::Any.new(part_name)
            if ps = read_trimmed("#{pdir}/size")
              part["sectors"] = JSON::Any.new(ps.to_i64?)
              part["size"] = JSON::Any.new(human_block_size(ps.to_i64? || 0_i64))
            end
            if st = read_trimmed("#{pdir}/start")
              part["start"] = JSON::Any.new(st.to_i64?)
            end
            partitions[part_name] = JSON::Any.new(part)
          end
          dev["partitions"] = JSON::Any.new(partitions)

          devices[name] = JSON::Any.new(dev)
        end
      rescue
        # No /sys/block at all (non-Linux, exotic container) - devices
        # stays {} and still gets set below.
      end

      # See the comment above: even {} must be set, never omitted.
      facts["ansible_devices"] = devices
    end

    # Real Ansible renders device/partition sizes as human strings
    # ("111.79 GB") via its human_size() helper - 1024-based units, two
    # decimals, starting from bytes (sysfs size is in 512-byte sectors).
    private def human_block_size(sectors : Int64) : String
      units = ["B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"]
      size = (sectors * 512).to_f
      unit = 0
      while size >= 1024 && unit < units.size - 1
        size /= 1024
        unit += 1
      end
      sprintf("%.2f %s", size, units[unit])
    end

    # Mount facts - a list of dicts, one per mounted filesystem, matching real
    # Ansible's ansible_mounts shape (mount/device/fstype/opts are the fields
    # roles like os_hardening read). Parsed from /proc/self/mountinfo rather
    # than forking `mount`, and bounded to real bind/devtmpfs noise that roles
    # filter on themselves.
    def gather_mount_facts(facts)
      mounts = [] of Hash(String, Int64 | String)

      begin
        File.read_lines("/proc/self/mountinfo").each do |line|
          # Format: mountID parentID major:minor root mountpoint options ...

          fields = line.split(" ")
          next if fields.size < 5

          # fields[4] is the mountpoint; the fstype and source sit after the
          # " - " separator (mountinfo: `... - fstype source superopts ...`).
          sep = fields.index("-")
          next unless sep

          fstype = fields[sep + 1]?
          source = fields[sep + 2]?
          next if fstype.nil? || source.nil?

          # mountinfo options are comma-joined with escaping; keep them raw -
          # roles only compare/map on mount/fstype, not individual options here.
          opts = fields[5]?

          entry = {
            "mount"  => fields[4],
            "device" => source,
            "fstype" => fstype,
            "opts"   => opts || "",
          } of String => Int64 | String
          entry.merge!(gather_mount_space_stats(fields[4]))
          mounts << entry
        end
      rescue
        # If mountinfo is unreadable (unusual), fall back to /etc/mtab.
        begin
          File.read_lines("/etc/mtab").each do |line|
            parts = line.split(/\s+/)
            next unless parts.size >= 3
            entry = {
              "mount"  => parts[1],
              "device" => parts[0],
              "fstype" => parts[2],
              "opts"   => parts[3]? || "",
            } of String => Int64 | String
            entry.merge!(gather_mount_space_stats(parts[1]))
            mounts << entry
          end
        rescue
          # Nothing - leave mounts empty rather than fail the whole gather.
        end
      end

      facts["ansible_mounts"] = mounts unless mounts.empty?
    end

    # Real Ansible's own `ansible_facts['mounts']` entries always include
    # space/inode statistics (`size_total`/`size_available`/`block_size`/
    # `block_total`/`block_available`/`block_used`/`inode_total`/
    # `inode_available`/`inode_used`, from `os.statvfs()` on each mountpoint)
    # alongside mount/device/fstype/opts - this plugin only ever populated the
    # latter, so any role reading the former (robertdebock.diskspace's whole
    # purpose: `item.size_available | int >= kilobytes_available | int`) saw
    # an undefined field and either crashed or - worse - silently never
    # actually checked anything, since the role's own `when: mount.name ==
    # item.mount` guard still matched the real mountpoint correctly; the
    # comparison inside the assert is what broke. Uses `stat -f` (present on
    # every target this repo benchmarks) rather than a raw statvfs(2) FFI
    # binding - matches the same fields real Ansible's own `os.statvfs()`
    # reads, just fetched via a subprocess instead of a syscall:
    #   %S block_size (statvfs.f_frsize)   %b block_total (f_blocks)
    #   %f block_free, all users (f_bfree) %a block_available, non-root (f_bavail)
    #   %c inode_total (f_files)           %d inode_free, non-root (f_favail)
    # Returned as strings (matching this plugin's existing Hash(String,String)
    # mount-entry shape) - real Ansible's own `| int` filter chain in the
    # role already coerces the field before comparing, so a numeric-looking
    # string round-trips identically to a real int for that purpose.
    def gather_mount_space_stats(mountpoint : String) : Hash(String, Int64 | String)
      output = IO::Memory.new
      status = Process.run("stat", ["-f", "--format=%S %b %f %a %c %d", mountpoint], output: output, error: Process::Redirect::Close)
      return {} of String => Int64 | String unless status.success?

      parts = output.to_s.strip.split(" ")
      return {} of String => Int64 | String unless parts.size == 6

      block_size, block_total, block_free, block_available, inode_total, inode_free =
        parts.map(&.to_i64?)

      return {} of String => Int64 | String if block_size.nil? || block_total.nil? || block_free.nil? ||
                                               block_available.nil? || inode_total.nil? || inode_free.nil?

      # Real Ansible's own ansible_mounts entries carry the space/inode
      # stats as INTEGERS, not strings - roles do real arithmetic on them
      # (`{{ (mnt.size_total / 1024 / 1024 / 1024) | round(1) }}`,
      # mullholland.motd's motd.j2, round 300197), which failed with
      # Crinja's "Both operators need to be numeric" while the values
      # were strings. The dict's own String fields (mount/device/fstype/
      # opts) stay strings.
      {
        "size_total"      => block_size * block_total,
        "size_available"  => block_size * block_available,
        "block_size"      => block_size,
        "block_total"     => block_total,
        "block_available" => block_available,
        "block_used"      => block_total - block_free,
        "inode_total"     => inode_total,
        "inode_available" => inode_free,
        "inode_used"      => inode_total - inode_free,
      } of String => Int64 | String
    end

    def gather_python_facts(facts, remote_connection : Bool = false)
      # Real Ansible's PythonFactCollector exposes ansible_facts['python'] as
      # a single nested dict (version/version_info/executable/
      # has_sslcontext/type) - not the flat ansible_python (path string) /
      # ansible_python_version (bare version string) this used to invent,
      # which don't exist under those names in real Ansible at all. Asking
      # the interpreter to introspect itself (like Ansible's own collector
      # does, running inside Python) is more robust than re-deriving each
      # field by shelling out separately.
      python_bin = Process.find_executable("python3") || Process.find_executable("python")
      return unless python_bin

      script = <<-PY
        import json, sys
        vi = sys.version_info
        print(json.dumps({
            "major": vi[0], "minor": vi[1], "micro": vi[2],
            "releaselevel": vi[3], "serial": vi[4],
            "version_info": list(vi),
            "executable": sys.executable,
            "has_sslcontext": True,
            "type": getattr(sys, "subversion", [getattr(sys, "implementation", type("", (), {"name": None})).name])[0],
        }))
        PY

      raw = capture_merged(python_bin, ["-c", script])
      parsed = (JSON.parse(raw).as_h? rescue nil)
      return unless parsed

      facts["ansible_python"] = {
        "version" => JSON::Any.new({
          "major"        => JSON::Any.new(parsed["major"].as_i64),
          "minor"        => JSON::Any.new(parsed["minor"].as_i64),
          "micro"        => JSON::Any.new(parsed["micro"].as_i64),
          "releaselevel" => parsed["releaselevel"],
          "serial"       => JSON::Any.new(parsed["serial"].as_i64),
        } of String => JSON::Any),
        "version_info"   => parsed["version_info"],
        "executable"     => parsed["executable"],
        "has_sslcontext" => parsed["has_sslcontext"],
        "type"           => parsed["type"],
      } of String => JSON::Any

      # Real Ansible also exposes a separate flat `ansible_python_version`
      # ("major.minor.micro", e.g. "3.10.12") alongside the nested `ansible_python`
      # dict above - both co-exist in real `setup` output. Found benchmarking
      # robertdebock/prometheus.prometheus.alertmanager round 134:
      # prometheus.prometheus's own `_common_dependencies` var does
      # `ansible_facts['python_version'] is version('3', '<')` to pick
      # python-apt vs python3-apt - with this fact missing entirely, the
      # version test compared against Crinja's `Undefined` sentinel and
      # silently evaluated true, always picking the wrong (nonexistent on
      # modern Ubuntu) `python-apt` package name.
      facts["ansible_python_version"] = "#{parsed["major"]}.#{parsed["minor"]}.#{parsed["micro"]}"

      # ansible_python_interpreter - real Ansible's own flat magic var,
      # but ONLY when the module is running on the CONTROLLER itself
      # (a genuine ansible_connection: local target, where it's simply
      # sys.executable) - live-verified against ansible-core 2.19.4 over
      # a real SSH connection that a genuinely remote target NEVER
      # defines this var at all: interpreter discovery still happens
      # (its own warning still prints) but the result is exposed only
      # internally, never as a templatable fact. `remote_connection`
      # (threaded down from TaskExecutor#gather_facts_for_host_measured,
      # which already knows whether this plugin got uploaded and run via
      # a real SSH round trip) is exactly that distinction.
      #
      # 0.9.652 originally set this UNCONDITIONALLY, reasoning from
      # azavea.pip's own idiom `{{ ansible_python_interpreter if
      # ansible_python_interpreter is defined else 'python' }}` - but
      # that reasoning was never verified against a genuine remote SSH
      # target (real ansible-core FAILS azavea.pip's task the exact same
      # way krikri did before 0.9.652, both engines identically broken -
      # not a divergence at all). Always-defining it instead created a
      # NEW, real divergence: geerlingguy.mysql's own `{% if 'python3' in
      # ansible_python_interpreter|default('') %}` branch (deciding
      # between the `python-mysqldb`/`python3-mysqldb` package names)
      # always took the wrong (krikri-only-defined) branch on a real
      # remote host. Reuses the same python_bin this method already
      # resolved above rather than re-discovering it, for the local case.
      facts["ansible_python_interpreter"] = python_bin unless remote_connection
    end

    def gather_user_facts(facts)
      # Real Ansible's setup derives these from getpwuid(getuid()), NOT from
      # the environment - and the difference is observable: the facts plugin
      # runs remotely inside a non-login SSH shell where USER/HOME/SHELL are
      # frequently unset, so the ENV lookups silently skipped ansible_user_id/
      # _dir/_shell entirely on remote hosts (buluma.ara_api's own
      # `ara_api_root_dir: "{{ ansible_facts['user_dir'] }}/.ara"` default then
      # hard-failed with 'ara_api_root_dir' is undefined remotely while the
      # identical playbook ran clean locally, round 190). pw_name/pw_dir/
      # pw_shell from getpwuid are always present; ENV only fills a fact the
      # passwd entry somehow lacks. (getpwuid isn't in Crystal's own LibC
      # bindings, hence the local lib declaration - glibc's struct passwd
      # layout, verified against getpwuid(3).)
      if pw = PASSWD.getpwuid(LibC.getuid.to_u32)
        facts["ansible_user_id"] = String.new(pw.value.pw_name) unless facts["ansible_user_id"]?
        facts["ansible_user_dir"] = String.new(pw.value.pw_dir) unless facts["ansible_user_dir"]?
        facts["ansible_user_shell"] = String.new(pw.value.pw_shell) unless facts["ansible_user_shell"]?
        facts["ansible_user_gecos"] = String.new(pw.value.pw_gecos) unless facts["ansible_user_gecos"]?
      end

      if user = ENV["USER"]?
        facts["ansible_user_id"] ||= user
      end

      facts["ansible_user_uid"] = LibC.getuid.to_i64
      facts["ansible_user_gid"] = LibC.getgid.to_i64

      if home = ENV["HOME"]?
        facts["ansible_user_dir"] ||= home
      end

      if shell = ENV["SHELL"]?
        facts["ansible_user_shell"] ||= shell
      end
    end

    def gather_environment_facts(facts)
      env_vars = ["PATH", "HOME", "USER", "SHELL", "TERM", "LANG"]
      env = {} of String => String

      env_vars.each do |var|
        if value = ENV[var]?
          env[var] = value
        end
      end

      facts["ansible_env"] = env unless env.empty?
    end

    def gather_date_time_facts(facts)
      now = Time.utc
      local = Time.local

      date_time = {} of String => String

      date_time["epoch"] = now.to_unix.to_s
      date_time["iso8601"] = now.to_s("%Y-%m-%dT%H:%M:%SZ")
      date_time["date"] = local.to_s("%Y-%m-%d")
      date_time["time"] = local.to_s("%H:%M:%S")
      date_time["year"] = local.year.to_s
      date_time["month"] = local.month.to_s.rjust(2, '0')
      date_time["day"] = local.day.to_s.rjust(2, '0')
      date_time["hour"] = local.hour.to_s.rjust(2, '0')
      date_time["minute"] = local.minute.to_s.rjust(2, '0')
      date_time["second"] = local.second.to_s.rjust(2, '0')
      date_time["weekday"] = local.to_s("%A")
      date_time["weekday_number"] = local.day_of_week.value.to_s

      tz = local.zone.name
      date_time["tz"] = tz unless tz.empty?

      facts["ansible_date_time"] = date_time
    end

    # fact_path - real Ansible's local facts mechanism
    # (module_utils/facts/system/local.py): every *.fact file in
    # *fact_path* (real default /etc/ansible/facts.d) becomes a key under
    # ansible_local. Executable files are RUN and their stdout parsed;
    # the rest are read in place. Content must parse as JSON, else as
    # ini (section-REQUIRED - a bare `key=value` with no [section] header
    # is configparser's MissingSectionHeaderError, live-verified, and
    # yields the same "error loading facts as JSON or ini - please check
    # content:" error string real Ansible stores as the fact's value);
    # unparseable content is stored as that error string, never fatal.
    def gather_local_facts(fact_path : String?) : Hash(String, JSON::Any)
      local = {} of String => JSON::Any
      return local if fact_path.nil? || fact_path.empty? || !Dir.exists?(fact_path)

      Dir.glob("#{fact_path}/*.fact").sort.each do |fact_file|
        fact_base = File.basename(fact_file).chomp(".fact")

        begin
          executable = File.info(fact_file).permissions.owner_execute?
        rescue e
          local[fact_base] = JSON::Any.new("Could not stat fact (#{fact_file}): #{e.message}")
          next
        end

        content = ""
        if executable
          err = IO::Memory.new
          out_io = IO::Memory.new
          begin
            status = Process.run(fact_file, shell: false, output: out_io, error: err)
            if status.exit_code != 0
              local[fact_base] = JSON::Any.new("Failure executing fact script (#{fact_file}), rc: #{status.exit_code}, err: #{err}")
              next
            end
            content = out_io.to_s
          rescue e
            local[fact_base] = JSON::Any.new("Could not execute fact script (#{fact_file}): #{e.message}")
            next
          end
        else
          content = File.read(fact_file) rescue ""
        end

        local[fact_base] = parse_local_fact(content, fact_file)
      end

      local
    end

    # One fact file's content: JSON first, then ini (sections become
    # nested dicts, values stay strings), else the exact error string
    # real Ansible stores. INI parsing mirrors configparser closely
    # enough for fact files: [section] headers are REQUIRED, `key=value`
    # (or `key: value`) pairs inside, `#`/`;` comments and blank lines
    # skipped, whitespace around keys/values stripped.
    private def parse_local_fact(content : String, fn : String) : JSON::Any
      begin
        return JSON.parse(content)
      rescue
      end

      sections = Hash(String, Hash(String, String)).new
      current : String? = nil
      saw_header = false

      content.each_line do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.starts_with?("#") || stripped.starts_with?(";")

        if stripped.starts_with?("[") && stripped.ends_with?("]") && stripped.size >= 3
          current = stripped[1..-2]
          saw_header = true
          sections[current] ||= Hash(String, String).new
          next
        end

        header = current
        sep = stripped.index('=') || stripped.index(':')
        if header.nil? || sep.nil?
          # A key line outside any [section] is what configparser
          # rejects the whole file over.
          return JSON::Any.new("error loading facts as JSON or ini - please check content: #{fn}")
        end
        key = stripped[0...sep].strip
        value = stripped[(sep + 1)..].strip
        sections[header][key] = value
      end

      unless saw_header
        return JSON::Any.new("error loading facts as JSON or ini - please check content: #{fn}")
      end

      parsed = Hash(String, JSON::Any).new
      sections.each do |section, pairs|
        parsed[section] = JSON.parse(pairs.to_json)
      end
      JSON.parse(parsed.to_json)
    end

    # filter - real Ansible's fnmatch (shell-style glob) filter over the
    # TOP-LEVEL fact keys only, applied after gathering. Empty patterns
    # mean no filter (live-verified: filter="" returns everything).
    def apply_fact_filter(facts : FactSet, patterns : Array(String)) : FactSet
      return facts if patterns.empty?
      regexes = patterns.map { |pattern| fnmatch_to_regex(pattern) }

      filtered = FactSet.new
      facts.each do |key, value|
        filtered[key] = value if regexes.any?(&.matches?(key))
      end
      filtered
    end

    # Python fnmatch.translate's glob dialect: *, ?, [seq], [!seq] -
    # an unterminated [ is a literal. Case-sensitive (posix fnmatch).
    def fnmatch_to_regex(pattern : String) : Regex
      regex = IO::Memory.new
      regex << "\\A"
      i = 0
      while i < pattern.size
        c = pattern[i]
        case c
        when '*'
          regex << ".*"
          i += 1
        when '?'
          regex << "."
          i += 1
        when '['
          close = pattern.index(']', i + 1)
          if close && close > i + 1
            inner = pattern[(i + 1)...close]
            if inner.starts_with?('!')
              regex << "[^#{Regex.escape(inner[1..])}]"
            else
              regex << "[#{inner}]"
            end
            i = close + 1
          else
            regex << "\\["
            i += 1
          end
        else
          regex << Regex.escape(c.to_s)
          i += 1
        end
      end
      regex << "\\Z"
      Regex.new(regex.to_s)
    end

    # The former `# Entry point` block, with the two differences that
    # make it serve both callers: *config* arrives already parsed (the
    # daemon hands over a `JSON::Any`; the standalone driver parses
    # STDIN itself), and the JSON is RETURNED rather than printed, since
    # the daemon frames the response itself. `nil` means "no config at
    # all", which the standalone path can legitimately see and which
    # means real Ansible's argument-spec defaults (gather_subset=all,
    # gather_timeout=10, no filter, fact_path=/etc/ansible/facts.d).
    def run(config : JSON::Any?) : String
      params = config.try(&.["params"]?)

      # gather_subset: comma-separated in string form (type=list in real
      # Ansible's argument spec, whose check_type_list splits on ','
      # WITHOUT stripping - live-verified: "network, virtual" with a
      # space FAILS the real module with "Bad subset ' virtual'"), or an
      # actual list when the playbook passed YAML list form.
      requested_subset = ["all"]
      params.try(&.["gather_subset"]?).try do |raw|
        if list = raw.as_a?
          requested_subset = list.compact_map(&.as_s?)
        else
          raw.as_s?.try do |subset_string|
            requested_subset = subset_string.split(',').reject(&.empty?)
          end
        end
      end

      gather_timeout = parse_gather_timeout(params)
      filter_spec = parse_filter_spec(params)
      fact_path = params.try(&.["fact_path"]?).try(&.as_s?) || DEFAULT_FACT_PATH

      remote_connection = params.try(&.["_remote_connection"]?).try(&.as_s?) == "true"

      facts = gather_facts(requested_subset, remote_connection, gather_timeout, fact_path)

      # Real Ansible's own meta facts - every setup result carries the
      # requested subset list and module_setup under ansible_facts
      # (live-verified), filtered like every other top-level key.
      facts["gather_subset"] = requested_subset
      facts["module_setup"] = true

      facts = apply_fact_filter(facts, filter_spec)

      {
        "changed"       => false,
        "failed"        => false,
        "ansible_facts" => facts,
      }.to_json
    rescue ex : BadSubsetError
      {
        "changed" => false,
        "failed"  => true,
        "msg"     => ex.message,
      }.to_json
    rescue ex
      STDERR.puts ex.backtrace.join("\n")
      {
        "changed" => false,
        "failed"  => true,
        "msg"     => "Facts gathering failed: #{ex.message}",
      }.to_json
    end

    # gather_timeout - type=int in real Ansible's argument spec: arrives
    # as a JSON number or a numeric string; anything else fails the
    # module with the exact shape real check_type_int produces
    # (live-verified: `gather_timeout: "abc"` -> "argument
    # 'gather_timeout' is of type str and we were unable to convert to
    # int: ..."). Absent means real's 10-second default.
    private def parse_gather_timeout(params : JSON::Any?) : Int64?
      raw = params.try(&.["gather_timeout"]?) || return nil
      if n = raw.as_i64?
        return n
      end
      if s = raw.as_s?
        if n = s.strip.to_i64?
          return n
        end
        raise BadSubsetError.new("argument 'gather_timeout' is of type str and we were unable to convert to int: \"'#{s}'\" cannot be converted to an int")
      end
      nil
    end

    # filter - type=list in real Ansible's argument spec: a plain string
    # is comma-split (no strip, same as gather_subset), a YAML list
    # arrives as a JSON array. Empty/blank patterns are dropped, making
    # an empty spec "no filter" exactly as live-verified.
    private def parse_filter_spec(params : JSON::Any?) : Array(String)
      raw = params.try(&.["filter"]?) || return [] of String
      if list = raw.as_a?
        return list.compact_map(&.as_s?).reject(&.empty?)
      end
      if s = raw.as_s?
        return s.split(',').reject(&.empty?)
      end
      [] of String
    end
  end
end
