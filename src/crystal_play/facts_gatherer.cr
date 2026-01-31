require "json"

module CrystalPlay
  # Facts Gatherer
  # Gathers system facts about remote hosts (Ansible-compatible)
  # Populates ansible_* variables automatically
  
  class FactsGatherer
    @ssh_manager : SSHManager
    @host : Host
    
    def initialize(@ssh_manager : SSHManager, @host : Host)
    end
    
    # Gather all facts and return as Hash
    def gather : Hash(String, JSON::Any)
      facts = Hash(String, JSON::Any).new
      
      # Gather basic facts
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
    private def gather_hostname(facts : Hash(String, JSON::Any))
      # ansible_hostname - short hostname
      result = execute_command("hostname -s")
      facts["ansible_hostname"] = JSON::Any.new(result.strip) if result
      
      # ansible_fqdn - fully qualified domain name
      result = execute_command("hostname -f")
      facts["ansible_fqdn"] = JSON::Any.new(result.strip) if result
      
      # ansible_nodename - same as hostname
      facts["ansible_nodename"] = facts["ansible_hostname"] if facts["ansible_hostname"]?
      
      # ansible_domain - domain name
      if fqdn = facts["ansible_fqdn"]?.try(&.as_s)
        if hostname = facts["ansible_hostname"]?.try(&.as_s)
          domain = fqdn.gsub(/^#{hostname}\./, "")
          facts["ansible_domain"] = JSON::Any.new(domain) unless domain.empty?
        end
      end
    end
    
    # Gather OS/distribution facts
    private def gather_os_facts(facts : Hash(String, JSON::Any))
      # Detect OS from /etc/os-release (standard on modern Linux)
      os_release = execute_command("cat /etc/os-release 2>/dev/null || cat /usr/lib/os-release 2>/dev/null")
      
      if os_release
        os_info = parse_os_release(os_release)
        
        # ansible_distribution - OS name (Ubuntu, CentOS, Debian, etc.)
        if id = os_info["ID"]?
          distribution = id.capitalize
          # Handle special cases
          distribution = "Ubuntu" if id == "ubuntu"
          distribution = "Debian" if id == "debian"
          distribution = "CentOS" if id.includes?("centos")
          distribution = "RedHat" if id.includes?("rhel")
          distribution = "Fedora" if id == "fedora"
          distribution = "Rocky" if id == "rocky"
          distribution = "AlmaLinux" if id == "almalinux"
          
          facts["ansible_distribution"] = JSON::Any.new(distribution)
        end
        
        # ansible_distribution_version - OS version
        if version = os_info["VERSION_ID"]?
          facts["ansible_distribution_version"] = JSON::Any.new(version)
        end
        
        # ansible_distribution_release - release name
        if release = os_info["VERSION_CODENAME"]?
          facts["ansible_distribution_release"] = JSON::Any.new(release)
        end
        
        # ansible_distribution_major_version - major version number
        if version = os_info["VERSION_ID"]?
          major = version.split(".").first
          facts["ansible_distribution_major_version"] = JSON::Any.new(major)
        end
      end
      
      # ansible_os_family - OS family (Debian, RedHat, etc.)
      if distro = facts["ansible_distribution"]?.try(&.as_s)
        os_family = case distro
        when "Ubuntu", "Debian"
          "Debian"
        when "CentOS", "RedHat", "Fedora", "Rocky", "AlmaLinux"
          "RedHat"
        when "Arch"
          "Arch"
        when "SUSE", "openSUSE"
          "Suse"
        when "Alpine"
          "Alpine"
        else
          "Linux"
        end
        facts["ansible_os_family"] = JSON::Any.new(os_family)
      end
      
      # ansible_system - OS type (always Linux for now)
      facts["ansible_system"] = JSON::Any.new("Linux")
      
      # ansible_kernel - kernel version
      kernel = execute_command("uname -r")
      facts["ansible_kernel"] = JSON::Any.new(kernel.strip) if kernel
      
      # ansible_kernel_version - same as kernel
      facts["ansible_kernel_version"] = facts["ansible_kernel"] if facts["ansible_kernel"]?
      
      # ansible_machine - architecture
      arch = execute_command("uname -m")
      facts["ansible_machine"] = JSON::Any.new(arch.strip) if arch
      
      # ansible_architecture - same as machine
      facts["ansible_architecture"] = facts["ansible_machine"] if facts["ansible_machine"]?
      
      # ansible_userspace_architecture - userspace arch
      userspace_arch = execute_command("dpkg --print-architecture 2>/dev/null || rpm --eval '%{_arch}' 2>/dev/null || uname -m")
      facts["ansible_userspace_architecture"] = JSON::Any.new(userspace_arch.strip) if userspace_arch
    end
    
    # Parse /etc/os-release format
    private def parse_os_release(content : String) : Hash(String, String)
      info = Hash(String, String).new
      
      content.each_line do |line|
        line = line.strip
        next if line.empty? || line.starts_with?("#")
        
        if line.includes?("=")
          key, value = line.split("=", 2)
          # Remove quotes
          value = value.gsub(/^["']|["']$/, "")
          info[key] = value
        end
      end
      
      info
    end
    
    # Gather network facts
    private def gather_network_facts(facts : Hash(String, JSON::Any))
      # ansible_default_ipv4 - default IPv4 address
      ipv4 = execute_command("ip -4 route get 1 2>/dev/null | head -1 | awk '{print $7}'")
      if ipv4 && !ipv4.strip.empty?
        facts["ansible_default_ipv4"] = JSON::Any.new({
          "address" => ipv4.strip
        })
      end
      
      # ansible_all_ipv4_addresses - all IPv4 addresses
      all_ipv4 = execute_command("ip -4 addr show | grep 'inet ' | awk '{print $2}' | cut -d/ -f1")
      if all_ipv4
        addresses = all_ipv4.split("\n").map(&.strip).reject(&.empty?)
        facts["ansible_all_ipv4_addresses"] = JSON::Any.new(addresses.map { |a| JSON::Any.new(a) })
      end
      
      # ansible_hostname with IP fallback
      unless facts["ansible_hostname"]?
        if ipv4 && !ipv4.strip.empty?
          facts["ansible_hostname"] = JSON::Any.new(ipv4.strip)
        end
      end
    end
    
    # Gather hardware facts
    private def gather_hardware_facts(facts : Hash(String, JSON::Any))
      # ansible_memtotal_mb - total memory in MB
      meminfo = execute_command("cat /proc/meminfo")
      if meminfo && meminfo.includes?("MemTotal")
        if match = meminfo.match(/MemTotal:\s+(\d+)/)
          mem_kb = match[1].to_i64
          mem_mb = mem_kb / 1024
          facts["ansible_memtotal_mb"] = JSON::Any.new(mem_mb)
        end
      end
      
      # ansible_memfree_mb - free memory in MB
      if meminfo && meminfo.includes?("MemAvailable")
        if match = meminfo.match(/MemAvailable:\s+(\d+)/)
          mem_kb = match[1].to_i64
          mem_mb = mem_kb / 1024
          facts["ansible_memfree_mb"] = JSON::Any.new(mem_mb)
        end
      end
      
      # ansible_processor_count - number of physical CPUs
      processor_count = execute_command("cat /proc/cpuinfo | grep 'physical id' | sort -u | wc -l")
      if processor_count && !processor_count.strip.empty?
        count = processor_count.strip.to_i
        count = 1 if count == 0 # Default to 1 if detection fails
        facts["ansible_processor_count"] = JSON::Any.new(count)
      end
      
      # ansible_processor_cores - cores per CPU
      cores = execute_command("cat /proc/cpuinfo | grep 'cpu cores' | head -1 | awk '{print $4}'")
      if cores && !cores.strip.empty?
        facts["ansible_processor_cores"] = JSON::Any.new(cores.strip.to_i)
      end
      
      # ansible_processor_vcpus - total virtual CPUs
      vcpus = execute_command("nproc 2>/dev/null || grep -c processor /proc/cpuinfo")
      if vcpus && !vcpus.strip.empty?
        facts["ansible_processor_vcpus"] = JSON::Any.new(vcpus.strip.to_i)
      end
      
      # ansible_processor - CPU model
      cpu_model = execute_command("cat /proc/cpuinfo | grep 'model name' | head -1 | cut -d: -f2")
      if cpu_model && !cpu_model.strip.empty?
        facts["ansible_processor"] = JSON::Any.new([cpu_model.strip])
      end
      
      # ansible_swaptotal_mb - swap space in MB
      if meminfo && meminfo.includes?("SwapTotal")
        if match = meminfo.match(/SwapTotal:\s+(\d+)/)
          swap_kb = match[1].to_i64
          swap_mb = swap_kb / 1024
          facts["ansible_swaptotal_mb"] = JSON::Any.new(swap_mb)
        end
      end
      
      # ansible_swapfree_mb - free swap in MB
      if meminfo && meminfo.includes?("SwapFree")
        if match = meminfo.match(/SwapFree:\s+(\d+)/)
          swap_kb = match[1].to_i64
          swap_mb = swap_kb / 1024
          facts["ansible_swapfree_mb"] = JSON::Any.new(swap_mb)
        end
      end
    end
    
    # Gather Python facts
    private def gather_python_facts(facts : Hash(String, JSON::Any))
      # ansible_python_version - Python version
      python_version = execute_command("python3 --version 2>&1 | awk '{print $2}' || python --version 2>&1 | awk '{print $2}'")
      if python_version && !python_version.strip.empty?
        facts["ansible_python_version"] = JSON::Any.new(python_version.strip)
      end
      
      # ansible_python - Python interpreter path
      python_path = execute_command("which python3 2>/dev/null || which python 2>/dev/null")
      if python_path && !python_path.strip.empty?
        facts["ansible_python"] = JSON::Any.new(python_path.strip)
      end
    end
    
    # Gather user facts
    private def gather_user_facts(facts : Hash(String, JSON::Any))
      # ansible_user_id - current user
      user = execute_command("whoami")
      facts["ansible_user_id"] = JSON::Any.new(user.strip) if user
      
      # ansible_user_uid - user ID
      uid = execute_command("id -u")
      facts["ansible_user_uid"] = JSON::Any.new(uid.strip.to_i) if uid && !uid.strip.empty?
      
      # ansible_user_gid - group ID
      gid = execute_command("id -g")
      facts["ansible_user_gid"] = JSON::Any.new(gid.strip.to_i) if gid && !gid.strip.empty?
      
      # ansible_user_dir - user home directory
      home = execute_command("echo $HOME")
      facts["ansible_user_dir"] = JSON::Any.new(home.strip) if home
      
      # ansible_user_shell - user shell
      shell = execute_command("echo $SHELL")
      facts["ansible_user_shell"] = JSON::Any.new(shell.strip) if shell
    end
    
    # Gather environment facts
    private def gather_environment_facts(facts : Hash(String, JSON::Any))
      # ansible_env - environment variables (limited set)
      env_vars = ["PATH", "HOME", "USER", "SHELL", "TERM", "LANG"]
      env = Hash(String, JSON::Any).new
      
      env_vars.each do |var|
        value = execute_command("echo $#{var}")
        env[var] = JSON::Any.new(value.strip) if value && !value.strip.empty?
      end
      
      facts["ansible_env"] = JSON::Any.new(env) unless env.empty?
    end
    
    # Gather date/time facts
    private def gather_date_time_facts(facts : Hash(String, JSON::Any))
      # ansible_date_time - current date/time
      date_time = Hash(String, JSON::Any).new
      
      # epoch - Unix timestamp
      epoch = execute_command("date +%s")
      date_time["epoch"] = JSON::Any.new(epoch.strip) if epoch
      
      # iso8601 - ISO 8601 format
      iso8601 = execute_command("date -u +%Y-%m-%dT%H:%M:%SZ")
      date_time["iso8601"] = JSON::Any.new(iso8601.strip) if iso8601
      
      # date - YYYY-MM-DD
      date = execute_command("date +%Y-%m-%d")
      date_time["date"] = JSON::Any.new(date.strip) if date
      
      # time - HH:MM:SS
      time = execute_command("date +%H:%M:%S")
      date_time["time"] = JSON::Any.new(time.strip) if time
      
      # year, month, day
      year = execute_command("date +%Y")
      date_time["year"] = JSON::Any.new(year.strip) if year
      
      month = execute_command("date +%m")
      date_time["month"] = JSON::Any.new(month.strip) if month
      
      day = execute_command("date +%d")
      date_time["day"] = JSON::Any.new(day.strip) if day
      
      # hour, minute, second
      hour = execute_command("date +%H")
      date_time["hour"] = JSON::Any.new(hour.strip) if hour
      
      minute = execute_command("date +%M")
      date_time["minute"] = JSON::Any.new(minute.strip) if minute
      
      second = execute_command("date +%S")
      date_time["second"] = JSON::Any.new(second.strip) if second
      
      # weekday, weekday_number
      weekday = execute_command("date +%A")
      date_time["weekday"] = JSON::Any.new(weekday.strip) if weekday
      
      weekday_number = execute_command("date +%w")
      date_time["weekday_number"] = JSON::Any.new(weekday_number.strip) if weekday_number
      
      # timezone
      tz = execute_command("date +%Z")
      date_time["tz"] = JSON::Any.new(tz.strip) if tz
      
      facts["ansible_date_time"] = JSON::Any.new(date_time) unless date_time.empty?
    end
    
    # Execute command on remote host
    private def execute_command(cmd : String) : String?
      begin
        result = @ssh_manager.execute(@host, cmd)
        return result["stdout"].as_s if result["rc"].as_i == 0
        nil
      rescue
        nil
      end
    end
  end
end
