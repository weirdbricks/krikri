require "json"

module CrystalPlay
  # OSFacts - Gathers OS and distribution facts
  module OSFacts
    # Gather OS/distribution facts
    # Populates: ansible_distribution, ansible_distribution_version, ansible_os_family, etc.
    def self.gather(facts : Hash(String, JSON::Any), execute_callback : Proc(String, String?))
      # Detect OS from /etc/os-release (standard on modern Linux)
      os_release = execute_callback.call("cat /etc/os-release 2>/dev/null || cat /usr/lib/os-release 2>/dev/null")
      
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
      kernel = execute_callback.call("uname -r")
      facts["ansible_kernel"] = JSON::Any.new(kernel.strip) if kernel
      
      # ansible_kernel_version - same as kernel
      facts["ansible_kernel_version"] = facts["ansible_kernel"] if facts["ansible_kernel"]?
      
      # ansible_machine - architecture
      arch = execute_callback.call("uname -m")
      facts["ansible_machine"] = JSON::Any.new(arch.strip) if arch
      
      # ansible_architecture - same as machine
      facts["ansible_architecture"] = facts["ansible_machine"] if facts["ansible_machine"]?
      
      # ansible_userspace_architecture - userspace arch
      userspace_arch = execute_callback.call("dpkg --print-architecture 2>/dev/null || rpm --eval '%{_arch}' 2>/dev/null || uname -m")
      facts["ansible_userspace_architecture"] = JSON::Any.new(userspace_arch.strip) if userspace_arch
    end
    
    # Parse /etc/os-release format
    private def self.parse_os_release(content : String) : Hash(String, String)
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
  end
end
