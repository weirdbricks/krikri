#!/usr/bin/env crystal

# Facts Plugin - Fast system facts gathering
# Runs locally on target host and returns all facts in one JSON response

require "json"

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

# Gather all system facts
def gather_facts : Hash(String, String | Int64 | Hash(String, String) | Array(String) | Array(Hash(String, String)) | Hash(String, JSON::Any))
  facts = {} of String => (String | Int64 | Hash(String, String) | Array(String) | Array(Hash(String, String)) | Hash(String, JSON::Any))

  gather_hostname(facts)
  gather_os_facts(facts)
  gather_network_facts(facts)
  gather_hardware_facts(facts)
  gather_mount_facts(facts)
  gather_python_facts(facts)
  gather_user_facts(facts)
  gather_environment_facts(facts)
  gather_date_time_facts(facts)

  facts
end

# Gather hostname facts
def gather_hostname(facts)
  hostname = System.hostname
  facts["ansible_hostname"] = hostname
  facts["ansible_nodename"] = hostname
  
  fqdn = capture("hostname", ["-f"])
  facts["ansible_fqdn"] = fqdn unless fqdn.empty?
  
  if !fqdn.empty? && fqdn.includes?(".")
    domain = fqdn.sub(/^#{Regex.escape(hostname)}\./, "")
    facts["ansible_domain"] = domain unless domain.empty?
  end
end

# Gather OS facts
def gather_os_facts(facts)
  os_info = parse_os_release
  
  if os_info
    if id = os_info["ID"]?
      distribution = case id
      when "ubuntu" then "Ubuntu"
      when "debian" then "Debian"  
      when /centos/ then "CentOS"
      when /rhel/ then "RedHat"
      when "fedora" then "Fedora"
      when "rocky" then "Rocky"
      when "almalinux" then "AlmaLinux"
      else id.capitalize
      end
      facts["ansible_distribution"] = distribution
      
      # OS family
      os_family = case distribution
      when "Ubuntu", "Debian" then "Debian"
      when "CentOS", "RedHat", "Fedora", "Rocky", "AlmaLinux" then "RedHat"
      when "Arch" then "Arch"
      when "SUSE", "openSUSE" then "Suse"
      when "Alpine" then "Alpine"
      else "Linux"
      end
      facts["ansible_os_family"] = os_family
    end
    
    if version = os_info["VERSION_ID"]?
      facts["ansible_distribution_version"] = version
      major = version.split(".").first
      facts["ansible_distribution_major_version"] = major
    end
    
    if release = os_info["VERSION_CODENAME"]?
      facts["ansible_distribution_release"] = release
    end
  end

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
  # "1.0.0.0 via 192.168.1.1 dev eth0 src 192.168.1.50 uid 0" - $7 is the
  # source address (this host's own IP on the default route), $5 the
  # outbound interface name. Real Ansible's `ansible_default_ipv4` fact
  # includes both (plus more fields this doesn't bother gathering) -
  # `interface` specifically is what konstruktoid-hardening's
  # sysctl.ipv6.conf.j2 template reads (`ansible_facts.default_ipv4.
  # interface`) to scope an IPv6 sysctl key to the default route's own
  # interface. Omitting it left that lookup undefined, which the
  # `regex_replace` filter downstream can't operate on - failing the
  # whole template render.
  default_route = `ip -4 route get 1 2>/dev/null | head -1`.strip
  route_fields = default_route.split(/\s+/)
  ipv4 = route_fields[6]?.to_s
  interface = route_fields[4]?.to_s
  if !ipv4.empty?
    default_ipv4 = {"address" => ipv4}
    default_ipv4["interface"] = interface unless interface.empty?
    facts["ansible_default_ipv4"] = default_ipv4
  end
  
  all_ipv4 = `ip -4 addr show 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1`.strip
  unless all_ipv4.empty?
    addresses = all_ipv4.split("\n").map(&.strip).reject(&.empty?)
    facts["ansible_all_ipv4_addresses"] = addresses
  end
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
end

# Mount facts - a list of dicts, one per mounted filesystem, matching real
# Ansible's ansible_mounts shape (mount/device/fstype/opts are the fields
# roles like os_hardening read). Parsed from /proc/self/mountinfo rather
# than forking `mount`, and bounded to real bind/devtmpfs noise that roles
# filter on themselves.
def gather_mount_facts(facts)
  mounts = [] of Hash(String, String)

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
      }
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
        }
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
def gather_mount_space_stats(mountpoint : String) : Hash(String, String)
  output = IO::Memory.new
  status = Process.run("stat", ["-f", "--format=%S %b %f %a %c %d", mountpoint], output: output, error: Process::Redirect::Close)
  return {} of String => String unless status.success?

  parts = output.to_s.strip.split(" ")
  return {} of String => String unless parts.size == 6

  block_size, block_total, block_free, block_available, inode_total, inode_free =
    parts.map { |p| p.to_i64? }

  return {} of String => String if block_size.nil? || block_total.nil? || block_free.nil? ||
                                   block_available.nil? || inode_total.nil? || inode_free.nil?

  {
    "size_total"       => (block_size * block_total).to_s,
    "size_available"   => (block_size * block_available).to_s,
    "block_size"       => block_size.to_s,
    "block_total"      => block_total.to_s,
    "block_available"  => block_available.to_s,
    "block_used"       => (block_total - block_free).to_s,
    "inode_total"      => inode_total.to_s,
    "inode_available"  => inode_free.to_s,
    "inode_used"       => (inode_total - inode_free).to_s,
  }
end

def gather_python_facts(facts)
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
end

def gather_user_facts(facts)
  if user = ENV["USER"]?
    facts["ansible_user_id"] = user
  end
  
  facts["ansible_user_uid"] = LibC.getuid.to_i64
  facts["ansible_user_gid"] = LibC.getgid.to_i64
  
  if home = ENV["HOME"]?
    facts["ansible_user_dir"] = home
  end
  
  if shell = ENV["SHELL"]?
    facts["ansible_user_shell"] = shell
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

# Entry point
begin
  facts = gather_facts
  
  result = {
    "changed" => false,
    "failed" => false,
    "ansible_facts" => facts
  }
  
  puts result.to_json
rescue ex
  error = {
    "changed" => false,
    "failed" => true,
    "msg" => "Facts gathering failed: #{ex.message}"
  }
  puts error.to_json
  STDERR.puts ex.backtrace.join("\n")
end
