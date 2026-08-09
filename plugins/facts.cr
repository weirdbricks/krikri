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
def gather_facts : Hash(String, String | Int64 | Hash(String, String) | Array(String) | Array(Hash(String, String)))
  facts = {} of String => (String | Int64 | Hash(String, String) | Array(String) | Array(Hash(String, String)))

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
  
  facts["ansible_system"] = "Linux"

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
  ipv4 = `ip -4 route get 1 2>/dev/null | head -1 | awk '{print $7}'`.strip
  if !ipv4.empty?
    facts["ansible_default_ipv4"] = {"address" => ipv4}
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

      mounts << {
        "mount"  => fields[4],
        "device" => source,
        "fstype" => fstype,
        "opts"   => opts || "",
      }
    end
  rescue
    # If mountinfo is unreadable (unusual), fall back to /etc/mtab.
    begin
      File.read_lines("/etc/mtab").each do |line|
        parts = line.split(/\s+/)
        next unless parts.size >= 3
        mounts << {
          "mount"  => parts[1],
          "device" => parts[0],
          "fstype" => parts[2],
          "opts"   => parts[3]? || "",
        }
      end
    rescue
      # Nothing - leave mounts empty rather than fail the whole gather.
    end
  end

  facts["ansible_mounts"] = mounts unless mounts.empty?
end

def gather_python_facts(facts)
  raw = capture_merged("python3", ["--version"])
  raw = capture_merged("python", ["--version"]) if raw.empty?
  version = raw.split.size >= 2 ? raw.split[1] : ""
  facts["ansible_python_version"] = version unless version.empty?

  path = Process.find_executable("python3") || Process.find_executable("python") || ""
  facts["ansible_python"] = path unless path.empty?
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
