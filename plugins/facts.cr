#!/usr/bin/env crystal

# Facts Plugin - Fast system facts gathering  
# Runs locally on target host and returns all facts in one JSON response

require "json"

# Gather all system facts
def gather_facts : Hash(String, String | Int64 | Hash(String, String) | Array(String))
  facts = {} of String => (String | Int64 | Hash(String, String) | Array(String))
  
  gather_hostname(facts)
  gather_os_facts(facts)
  gather_network_facts(facts)
  gather_hardware_facts(facts)
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
  
  fqdn = `hostname -f 2>/dev/null`.strip
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
  
  kernel = `uname -r 2>/dev/null`.strip
  facts["ansible_kernel"] = kernel unless kernel.empty?
  facts["ansible_kernel_version"] = kernel unless kernel.empty?
  
  arch = `uname -m 2>/dev/null`.strip
  facts["ansible_machine"] = arch unless arch.empty?
  facts["ansible_architecture"] = arch unless arch.empty?
  
  userspace = `dpkg --print-architecture 2>/dev/null || rpm --eval '%{_arch}' 2>/dev/null || uname -m`.strip
  facts["ansible_userspace_architecture"] = userspace unless userspace.empty?
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
  
  if File.exists?("/proc/cpuinfo")
    cpuinfo = File.read("/proc/cpuinfo")
    
    physical_ids = cpuinfo.scan(/physical id\s+:\s+(\d+)/).map(&.[1]).uniq
    count = physical_ids.size
    count = 1_i64 if count == 0
    facts["ansible_processor_count"] = count.to_i64
    
    if match = cpuinfo.match(/cpu cores\s+:\s+(\d+)/)
      facts["ansible_processor_cores"] = match[1].to_i64
    end
    
    vcpus = cpuinfo.scan(/^processor\s+:/).size.to_i64
    facts["ansible_processor_vcpus"] = vcpus if vcpus > 0
    
    if match = cpuinfo.match(/model name\s+:\s+(.+)/)
      facts["ansible_processor"] = [match[1].strip]
    end
  end
end

def gather_python_facts(facts)
  version = `python3 --version 2>&1 | awk '{print $2}'`.strip
  if version.empty?
    version = `python --version 2>&1 | awk '{print $2}'`.strip
  end
  facts["ansible_python_version"] = version unless version.empty?
  
  path = `which python3 2>/dev/null`.strip
  if path.empty?
    path = `which python 2>/dev/null`.strip
  end
  facts["ansible_python"] = path unless path.empty?
end

def gather_user_facts(facts)
  if user = ENV["USER"]?
    facts["ansible_user_id"] = user
  end
  
  uid = `id -u 2>/dev/null`.strip
  facts["ansible_user_uid"] = uid.to_i64 unless uid.empty?
  
  gid = `id -g 2>/dev/null`.strip
  facts["ansible_user_gid"] = gid.to_i64 unless gid.empty?
  
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
  
  tz = `date +%Z 2>/dev/null`.strip
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
