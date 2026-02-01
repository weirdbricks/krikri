require "yaml"
require "./host"

module CrystalPlay
  # Inventory - represents the complete inventory
  class Inventory
    property hosts : Hash(String, Host)
    property groups : Hash(String, HostGroup)
    
    def initialize
      @hosts = Hash(String, Host).new
      @groups = Hash(String, HostGroup).new
      
      # Create default groups
      @groups["all"] = HostGroup.new("all")
      @groups["ungrouped"] = HostGroup.new("ungrouped")
    end
    
    # Get hosts matching a pattern
    def get_hosts(pattern : String) : Array(Host)
      case pattern
      when "all"
        @hosts.values
      when "localhost"
        # Special case for localhost
        if host = @hosts["localhost"]?
          [host]
        else
          # Create implicit localhost
          localhost = Host.new("localhost", ENV["USER"]? || "root", 22)
          localhost.vars["ansible_connection"] = JSON::Any.new("local")
          [localhost]
        end
      else
        # Check if it's a group
        if group = @groups[pattern]?
          group.hosts.values
        # Check if it's a host
        elsif host = @hosts[pattern]?
          [host]
        # Pattern matching (simple wildcards)
        elsif pattern.includes?("*")
          regex = pattern.gsub("*", ".*")
          @hosts.select { |name, _| name =~ /^#{regex}$/ }.values
        else
          # No match
          [] of Host
        end
      end
    end
    
    # Add a host
    def add_host(host : Host)
      @hosts[host.name] = host
    end
    
    # Add a group
    def add_group(group : HostGroup)
      @groups[group.name] = group
    end
    
    # Get or create group
    def get_or_create_group(name : String) : HostGroup
      @groups[name] ||= HostGroup.new(name)
    end
  end
  
  # Host group
  class HostGroup
    property name : String
    property hosts : Hash(String, Host)
    property children : Array(String)
    property vars : Hash(String, JSON::Any)
    
    def initialize(@name : String)
      @hosts = Hash(String, Host).new
      @children = [] of String
      @vars = Hash(String, JSON::Any).new
    end
    
    # Add host to group
    def add_host(host : Host)
      @hosts[host.name] = host
    end
    
    # Add child group
    def add_child(group_name : String)
      @children << group_name unless @children.includes?(group_name)
    end
  end
  
  # Inventory Parser - supports INI and YAML formats
  class InventoryParser
    # Parse inventory from file (auto-detect format)
    def self.parse(path : String) : Inventory
      unless File.exists?(path)
        raise "Inventory file not found: #{path}"
      end
      
      # Detect format by extension or content
      if path.ends_with?(".yml") || path.ends_with?(".yaml")
        parse_yaml(path)
      else
        # Default to INI format
        parse_ini(path)
      end
    end
    
    # Parse INI format inventory
    def self.parse_ini(path : String) : Inventory
      inventory = Inventory.new
      content = File.read(path)
      
      current_group : String? = nil
      group_type = :hosts  # :hosts or :vars or :children
      
      content.lines.each do |line|
        line = line.strip
        
        # Skip empty lines and comments
        next if line.empty? || line.starts_with?("#") || line.starts_with?(";")
        
        # Check for group header
        if line.starts_with?("[") && line.ends_with?("]")
          group_header = line[1..-2]
          
          # Check for :vars or :children
          if group_header.ends_with?(":vars")
            current_group = group_header[0..-6]
            group_type = :vars
          elsif group_header.ends_with?(":children")
            current_group = group_header[0..-10]
            group_type = :children
          else
            current_group = group_header
            group_type = :hosts
          end
          
          # Create group if it doesn't exist
          inventory.get_or_create_group(current_group) if current_group
          next
        end
        
        # Parse based on current context
        if current_group
          case group_type
          when :hosts
            parse_host_line(line, current_group, inventory)
          when :vars
            parse_var_line(line, current_group, inventory)
          when :children
            parse_child_line(line, current_group, inventory)
          end
        else
          # No group - add to ungrouped
          parse_host_line(line, "ungrouped", inventory)
        end
      end
      
      # Apply group vars to hosts
      apply_group_vars(inventory)
      
      inventory
    end
    
    # Parse YAML format inventory
    def self.parse_yaml(path : String) : Inventory
      inventory = Inventory.new
      
      begin
        yaml = YAML.parse(File.read(path))
      rescue ex : YAML::ParseException
        raise "Invalid YAML in inventory file: #{ex.message}"
      end
      
      # YAML inventory structure
      if all_group = yaml["all"]?
        parse_yaml_group("all", all_group, inventory)
      end
      
      # Apply group vars
      apply_group_vars(inventory)
      
      inventory
    end
    
    # Parse host line from INI
    private def self.parse_host_line(line : String, group_name : String, inventory : Inventory)
      # Format: hostname key=value key=value
      parts = line.split(/\s+/)
      return if parts.empty?
      
      hostname = parts[0]
      
      # Get or create host
      host = inventory.hosts[hostname]?
      unless host
        host = Host.new(hostname)
        inventory.add_host(host)
      end
      
      # Parse host variables
      parts[1..-1].each do |part|
        next unless part.includes?("=")
        
        key, value = part.split("=", 2)
        host.vars[key] = parse_value(value)
      end
      
      # Add host to group
      group = inventory.get_or_create_group(group_name)
      group.add_host(host)
      
      # Special handling for ansible_host
      if ansible_host = host.vars["ansible_host"]?
        # Don't modify host.name, but connection will use ansible_host
      end
      
      # Special handling for ansible_user
      if ansible_user = host.vars["ansible_user"]?.try(&.as_s?)
        host.user = ansible_user
      end
      
      # Special handling for ansible_port
      if ansible_port = host.vars["ansible_port"]?
        if port = ansible_port.as_i?
          host.port = port
        elsif port = ansible_port.as_s?.try(&.to_i?)
          host.port = port
        end
      end
    end
    
    # Parse variable line from INI
    private def self.parse_var_line(line : String, group_name : String, inventory : Inventory)
      return unless line.includes?("=")
      
      key, value = line.split("=", 2)
      group = inventory.get_or_create_group(group_name)
      group.vars[key.strip] = parse_value(value.strip)
    end
    
    # Parse child group line from INI
    private def self.parse_child_line(line : String, group_name : String, inventory : Inventory)
      child_group_name = line.strip
      group = inventory.get_or_create_group(group_name)
      group.add_child(child_group_name)
      
      # Ensure child group exists
      inventory.get_or_create_group(child_group_name)
    end
    
    # Parse YAML group
    private def self.parse_yaml_group(group_name : String, yaml : YAML::Any, inventory : Inventory)
      group = inventory.get_or_create_group(group_name)
      
      # Parse hosts
      if hosts_yaml = yaml["hosts"]?.try(&.as_h?)
        hosts_yaml.each do |hostname, host_vars|
          host = Host.new(hostname.to_s)
          
          # Parse host vars
          if host_vars.as_h?
            host_vars.as_h.each do |key, value|
              host.vars[key.to_s] = JSON.parse(value.to_json)
              
              # Handle special ansible vars
              case key.to_s
              when "ansible_user"
                host.user = value.as_s
              when "ansible_port"
                host.port = value.as_i
              end
            end
          end
          
          inventory.add_host(host)
          group.add_host(host)
        end
      end
      
      # Parse group vars
      if vars_yaml = yaml["vars"]?.try(&.as_h?)
        vars_yaml.each do |key, value|
          group.vars[key.to_s] = JSON.parse(value.to_json)
        end
      end
      
      # Parse children
      if children_yaml = yaml["children"]?.try(&.as_h?)
        children_yaml.each do |child_name, child_yaml|
          group.add_child(child_name.to_s)
          parse_yaml_group(child_name.to_s, child_yaml, inventory)
        end
      end
    end
    
    # Apply group variables to hosts
    private def self.apply_group_vars(inventory : Inventory)
      inventory.groups.each do |group_name, group|
        # Apply group vars to all hosts in the group
        group.hosts.each do |hostname, host|
          group.vars.each do |key, value|
            # Only set if not already set on host
            host.vars[key] ||= value
          end
        end
        
        # Recursively apply child group vars
        group.children.each do |child_name|
          if child_group = inventory.groups[child_name]?
            child_group.hosts.each do |hostname, host|
              group.vars.each do |key, value|
                host.vars[key] ||= value
              end
            end
          end
        end
      end
    end
    
    # Parse a value (attempt to infer type)
    private def self.parse_value(value : String) : JSON::Any
      # Remove quotes if present
      if (value.starts_with?('"') && value.ends_with?('"')) ||
         (value.starts_with?("'") && value.ends_with?("'"))
        value = value[1..-2]
      end
      
      # Try to parse as number
      if int_value = value.to_i?
        return JSON::Any.new(int_value.to_i64)
      end
      
      if float_value = value.to_f?
        return JSON::Any.new(float_value)
      end
      
      # Try to parse as boolean
      case value.downcase
      when "true", "yes"
        return JSON::Any.new(true)
      when "false", "no"
        return JSON::Any.new(false)
      end
      
      # Default to string
      JSON::Any.new(value)
    end
    
    # Validate inventory
    def self.validate(inventory : Inventory) : Array(String)
      warnings = [] of String
      
      if inventory.hosts.empty?
        warnings << "Inventory has no hosts"
      end
      
      # Check for hosts without required vars
      inventory.hosts.each do |name, host|
        unless host.user.presence
          warnings << "Host '#{name}' has no user specified"
        end
      end
      
      warnings
    end
    
    # Get inventory statistics
    def self.stats(inventory : Inventory) : Hash(String, Int32)
      {
        "hosts" => inventory.hosts.size,
        "groups" => inventory.groups.size - 2,  # Exclude 'all' and 'ungrouped'
        "vars" => inventory.groups.sum { |_, g| g.vars.size }
      }
    end
  end
end
