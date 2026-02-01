require "json"

module CrystalPlay
  # HardwareFacts - Gathers hardware-related facts
  module HardwareFacts
    # Gather hardware facts
    # Populates: ansible_memtotal_mb, ansible_processor_count, ansible_processor_cores, etc.
    def self.gather(facts : Hash(String, JSON::Any), execute_callback : Proc(String, String?))
      # ansible_memtotal_mb - total memory in MB
      meminfo = execute_callback.call("cat /proc/meminfo")
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
      processor_count = execute_callback.call("cat /proc/cpuinfo | grep 'physical id' | sort -u | wc -l")
      if processor_count && !processor_count.strip.empty?
        count = processor_count.strip.to_i
        count = 1 if count == 0 # Default to 1 if detection fails
        facts["ansible_processor_count"] = JSON::Any.new(count)
      end
      
      # ansible_processor_cores - cores per CPU
      cores = execute_callback.call("cat /proc/cpuinfo | grep 'cpu cores' | head -1 | awk '{print $4}'")
      if cores && !cores.strip.empty?
        facts["ansible_processor_cores"] = JSON::Any.new(cores.strip.to_i)
      end
      
      # ansible_processor_vcpus - total virtual CPUs
      vcpus = execute_callback.call("nproc 2>/dev/null || grep -c processor /proc/cpuinfo")
      if vcpus && !vcpus.strip.empty?
        facts["ansible_processor_vcpus"] = JSON::Any.new(vcpus.strip.to_i)
      end
      
      # ansible_processor - CPU model
      cpu_model = execute_callback.call("cat /proc/cpuinfo | grep 'model name' | head -1 | cut -d: -f2")
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
  end
end
