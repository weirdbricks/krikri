require "yaml"
require "./vault"
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

    # Real Ansible's host-pattern language: terms separated by `:` or
    # `,`, where a plain term is UNIONed, `!term` excludes and `&term`
    # intersects, applied left to right. Previously only a single term
    # was understood, so `web:db`, `!web`, `prod:!db` and `web:&prod` all
    # matched NOTHING - and, being a pattern that matches no hosts rather
    # than an error, the play was silently skipped.
    def get_hosts(pattern : String) : Array(Host)
      terms = split_pattern(pattern)
      return single_pattern_hosts(pattern) if terms.size <= 1 && !pattern.starts_with?('!') && !pattern.starts_with?('&')

      # A pattern that STARTS with an exclusion or intersection is
      # implicitly relative to every host: `!web` means "all except web",
      # not "nothing except web" (verified against ansible-core 2.19.4).
      first = terms.first
      result = (first.starts_with?('!') || first.starts_with?('&')) ? @hosts.values.dup : [] of Host

      terms.each do |term|
        case term[0]?
        when '!'
          excluded = single_pattern_hosts(term[1..]).map(&.name).to_set
          result.reject! { |host| excluded.includes?(host.name) }
        when '&'
          required = single_pattern_hosts(term[1..]).map(&.name).to_set
          result.select! { |host| required.includes?(host.name) }
        else
          single_pattern_hosts(term).each do |host|
            result << host unless result.any? { |existing| existing.name == host.name }
          end
        end
      end
      result
    end

    # Split on `:`/`,` while leaving an inventory RANGE alone -
    # `web[01:03]` is one term, not two.
    private def split_pattern(pattern : String) : Array(String)
      terms = [] of String
      current = String::Builder.new
      depth = 0

      pattern.each_char do |char|
        case char
        when '[' then depth += 1; current << char
        when ']' then depth -= 1 if depth > 0; current << char
        when ':', ','
          if depth > 0
            current << char
          else
            terms << current.to_s
            current = String::Builder.new
          end
        else current << char
        end
      end
      terms << current.to_s

      terms.map(&.strip).reject(&.empty?)
    end

    # Every host of *name*, following `:children` transitively - a parent
    # group's own `hosts` hash holds only hosts declared directly under
    # it, so a group defined purely as a parent (`[prod:children]`)
    # otherwise resolved to nothing at all.
    # Public so the executor can build the `groups` magic var with the
    # same transitive view (a parent group's own hosts hash is empty).
    def hosts_in_group(name : String, seen = Set(String).new) : Array(Host)
      return [] of Host unless group = @groups[name]?
      return [] of Host unless seen.add?(name)

      hosts = group.hosts.values.dup
      group.children.each do |child|
        hosts_in_group(child, seen).each do |host|
          hosts << host unless hosts.any? { |existing| existing.name == host.name }
        end
      end
      hosts
    end

    # One term of a pattern - the original single-pattern behavior.
    private def single_pattern_hosts(pattern : String) : Array(Host)
      case pattern
      when "all", "*"
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
        # Check if it's a group (children resolved transitively)
        if @groups.has_key?(pattern)
          hosts_in_group(pattern)
          # Check if it's a host
        elsif host = @hosts[pattern]?
          [host]
          # Pattern matching (simple wildcards)
        elsif pattern.includes?("*")
          # Crystal only caches non-interpolated regex literals - compile
          # once here rather than once per host inside the select block.
          regex = /^#{pattern.gsub("*", ".*")}$/
          @hosts.select { |name, _| name =~ regex }.values
        else
          # No match
          [] of Host
        end
      end
    end

    # Every group *host_name* belongs to, following :children upward, in
    # the sorted order real Ansible's `group_names` uses. Only "all" is
    # excluded (verified: a host in [web] under [prod:children] reports
    # exactly "prod, web").
    #
    # "ungrouped" is NOT excluded, though it used to be: real Ansible
    # reports `group_names == ["ungrouped"]` for a host that belongs to
    # no other group, and that is genuine membership rather than an
    # internal artifact like "all" - a host listed above any [section]
    # header reported no groups at all here. Found in a regression sweep
    # while adding directory inventories (0.9.610). It only ever shows
    # up for a host with no real group, since any grouped host is not in
    # "ungrouped" to begin with.
    def groups_for(host_name : String) : Array(String)
      @groups.keys.select do |group_name|
        next false if group_name == "all"
        hosts_in_group(group_name).any? { |host| host.name == host_name }
      end.sort!
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

    # Replaces this inventory's own hosts/groups with a freshly-parsed
    # inventory's data, in place - used by `meta: refresh_inventory`
    # (see TaskExecutor#execute_meta). Mutating in place, rather than
    # having the caller just swap in the new Inventory object wholesale,
    # is what lets a single shared instance (crystal-play.cr's own
    # `inventory` local plus every play's TaskExecutor `@inventory`, all
    # the SAME object) see the refresh without any callback/reference-
    # cell plumbing between the two - matches real Ansible's own
    # documented behavior, verified live: refreshing does NOT change
    # which hosts the CURRENT play iterates over (already fixed before
    # this runs), only what a LATER play's own `hosts:` pattern match
    # sees.
    def reload_from!(fresh : Inventory)
      @hosts = fresh.hosts
      @groups = fresh.groups
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
    # Real Ansible's INVENTORY_IGNORE_EXTS default: files with these
    # suffixes are skipped when an inventory DIRECTORY is read, so an
    # editor backup or a stray README next to the real sources doesn't
    # get parsed as inventory. Taken verbatim from `ansible-config dump`
    # on ansible-core 2.19.4.
    IGNORED_INVENTORY_EXTENSIONS = %w[
      .pyc .pyo .swp .bak ~ .rpm .md .txt .rst .orig .cfg .retry
    ]

    # Parse inventory from a file, a directory of inventory sources, or a
    # comma-separated host list (auto-detect).
    def self.parse(path : String) : Inventory
      # `-i "web1,web2,"` - real Ansible's host_list source. The trailing
      # comma is what disambiguates a single-host list from a filename
      # (`-i localhost` is a file; `-i localhost,` is a host list), which
      # is why the rule is "contains a comma", not "isn't a file".
      return parse_host_list(path) if path.includes?(',')

      return parse_directory(path) if File.directory?(path)

      unless File.exists?(path)
        raise "Inventory file not found: #{path}"
      end

      # An executable inventory file is a dynamic inventory script, same
      # detection rule real Ansible uses (the executable bit, not the
      # extension) - see parse_dynamic.
      if File::Info.executable?(path)
        return parse_dynamic(path)
      end

      # Detect format by extension or content
      if path.ends_with?(".yml") || path.ends_with?(".yaml")
        parse_yaml(path)
      else
        # Default to INI format
        parse_ini(path)
      end
    end

    # An inventory DIRECTORY: every source inside it is parsed and the
    # results merged, which is how real Ansible lets a project split
    # `production/` into `01-web.ini`, `02-db.ini`, `hosts.yml` and so
    # on. Sources are read in filename order; ignored extensions
    # (IGNORED_INVENTORY_EXTENSIONS), hidden files and nested
    # directories are skipped, as they are there.
    #
    # Group vars are re-applied AFTER the merge, not just per file: an
    # `[all:vars]` block in one file has to reach hosts defined in
    # another (verified against real Ansible), and each file's own
    # parse only ever saw its own hosts.
    def self.parse_directory(path : String) : Inventory
      merged = Inventory.new

      sources = Dir.children(path).sort!.map { |child| File.join(path, child) }
      sources.each do |source|
        next unless File.file?(source)
        next if File.basename(source).starts_with?('.')
        next if IGNORED_INVENTORY_EXTENSIONS.any? { |extension| source.ends_with?(extension) }

        merge_inventory(merged, parse(source))
      end

      apply_group_vars(merged)
      merged
    end

    # Folds *source* into *target*: hosts are unioned (a host named in
    # two files keeps both files' vars, later file winning per key), and
    # so are groups, their members, their children and their vars.
    private def self.merge_inventory(target : Inventory, source : Inventory) : Nil
      source.hosts.each do |name, host|
        if existing = target.hosts[name]?
          host.vars.each { |key, value| existing.vars[key] = value }
          existing.user = host.user if host.user
          existing.port = host.port
        else
          target.add_host(host)
        end
      end

      source.groups.each do |name, group|
        target_group = target.get_or_create_group(name)
        group.hosts.each_key do |hostname|
          # Deliberately the TARGET's copy of the host, so a host merged
          # from an earlier file stays one object across every group it
          # belongs to (group vars are applied through these references).
          if host = target.hosts[hostname]?
            target_group.add_host(host)
          end
        end
        group.children.each { |child| target_group.add_child(child) }
        group.vars.each { |key, value| target_group.vars[key] = value }
      end
    end

    # `-i "alpha,beta,"` - a literal list of hosts rather than a file.
    # Range syntax works here exactly as it does in an INI file
    # (`-i "web[01:03],"`), since real Ansible runs the same expansion
    # over host_list entries.
    def self.parse_host_list(path : String) : Inventory
      inventory = Inventory.new

      path.split(',').each do |entry|
        entry = entry.strip
        next if entry.empty?

        expand_host_range(entry).each do |hostname|
          host = Host.new(hostname)
          inventory.add_host(host)
          inventory.get_or_create_group("ungrouped").add_host(host)
          inventory.get_or_create_group("all").add_host(host)
        end
      end

      inventory
    end

    # Parse a dynamic inventory: run the executable with --list and parse
    # its JSON output, in Ansible's standard dynamic inventory shape:
    #
    #   {
    #     "group1": {"hosts": ["h1", "h2"], "vars": {...}, "children": [...]},
    #     "group2": ["h3"],                    # shorthand: bare host list
    #     "_meta": {"hostvars": {"h1": {...}}} # optional but preferred -
    #                                          # avoids a --host call per host
    #   }
    #
    # If the script doesn't provide _meta.hostvars, falls back to the
    # older, slower per-host `--host <name>` convention real Ansible also
    # supports. Only inventory scripts (the original, universal dynamic
    # inventory mechanism - any executable, any language) are implemented;
    # Ansible's newer YAML-defined inventory *plugins* (aws_ec2.yml and
    # friends, each with its own config schema and API calls) are not.
    def self.parse_dynamic(path : String) : Inventory
      inventory = Inventory.new

      output = IO::Memory.new
      error = IO::Memory.new
      status = Process.run(path, ["--list"], output: output, error: error)
      unless status.success?
        raise "Dynamic inventory script '#{path}' failed (--list): #{error.to_s.strip}"
      end

      begin
        json = JSON.parse(output.to_s)
      rescue ex : JSON::ParseException
        raise "Dynamic inventory script '#{path}' did not return valid JSON: #{ex.message}"
      end

      json.as_h.each do |group_name, group_data|
        next if group_name.to_s == "_meta"
        apply_dynamic_group(inventory, group_name.to_s, group_data)
      end

      has_meta = json["_meta"]?
      if hostvars = has_meta.try(&.["hostvars"]?).try(&.as_h?)
        hostvars.each do |hostname, vars_json|
          host = get_or_create_dynamic_host(inventory, hostname.to_s)
          apply_host_vars_json(host, vars_json)
        end
      elsif !has_meta
        # No _meta at all: this script only supports the older per-host
        # convention, so fetch each discovered host's vars individually.
        inventory.hosts.each_value do |host|
          fetch_dynamic_host_vars(path, host)
        end
      end

      load_group_and_host_vars(inventory, File.dirname(path))
      apply_group_vars(inventory)

      inventory
    end

    # Apply one top-level group entry from a dynamic inventory's --list
    # output - either the shorthand bare-array form or the full
    # {hosts:, vars:, children:} hash form.
    private def self.apply_dynamic_group(inventory : Inventory, group_name : String, group_data : JSON::Any)
      group = inventory.get_or_create_group(group_name)

      if hosts_array = group_data.as_a?
        hosts_array.each { |h| group.add_host(get_or_create_dynamic_host(inventory, h.as_s)) }
        return
      end

      hash = group_data.as_h?
      return unless hash

      if hosts_list = hash["hosts"]?.try(&.as_a?)
        hosts_list.each { |h| group.add_host(get_or_create_dynamic_host(inventory, h.as_s)) }
      end

      if vars_hash = hash["vars"]?.try(&.as_h?)
        vars_hash.each { |k, v| group.vars[k.to_s] = Vault.maybe_decrypt_json(v) }
      end

      if children = hash["children"]?.try(&.as_a?)
        children.each do |c|
          group.add_child(c.as_s)
          inventory.get_or_create_group(c.as_s)
        end
      end
    end

    private def self.get_or_create_dynamic_host(inventory : Inventory, name : String) : Host
      inventory.hosts[name]? || begin
        host = Host.new(name)
        inventory.add_host(host)
        host
      end
    end

    # Apply a hostvars hash (from _meta.hostvars or a --host call) to a
    # host, handling ansible_user/ansible_port the same way inline
    # inventory vars already do.
    private def self.apply_host_vars_json(host : Host, vars_json : JSON::Any)
      hash = vars_json.as_h?
      return unless hash

      hash.each do |key, value|
        key_str = key.to_s
        json_value = Vault.maybe_decrypt_json(value)
        host.vars[key_str] = json_value

        case key_str
        when "ansible_user"
          host.user = json_value.as_s? || host.user
        when "ansible_port"
          host.port = json_value.as_i? || json_value.as_s?.try(&.to_i?) || host.port
        end
      end
    end

    # Older/simpler dynamic inventory scripts (no _meta) expect one
    # `--host <name>` call per host instead.
    private def self.fetch_dynamic_host_vars(path : String, host : Host)
      output = IO::Memory.new
      status = Process.run(path, ["--host", host.name], output: output, error: Process::Redirect::Close)
      return unless status.success?

      begin
        json = JSON.parse(output.to_s)
      rescue
        return
      end

      apply_host_vars_json(host, json)
    end

    # Parse INI format inventory
    def self.parse_ini(path : String) : Inventory
      inventory = Inventory.new
      content = File.read(path)

      current_group : String? = nil
      group_type = :hosts # :hosts or :vars or :children

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

      # group_vars/host_vars directory files, then the inventory's own
      # inline [group:vars] sections - see load_group_and_host_vars for why
      # that order matters.
      load_group_and_host_vars(inventory, File.dirname(path))
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

      # group_vars/host_vars directory files, then the inventory's own
      # inline vars: blocks - see load_group_and_host_vars for why that
      # order matters.
      load_group_and_host_vars(inventory, File.dirname(path))
      apply_group_vars(inventory)

      inventory
    end

    # Expands one inventory host entry into every hostname it names.
    # Numeric bounds keep the zero-padding of the FIRST bound
    # (`web[01:03]` -> web01..web03), alphabetic bounds step through
    # letters, and an optional third field is the step
    # (`x[01:10:3]` -> x01 x04 x07 x10). Text on either side of the
    # bracket is preserved, so `srv[1:2].ex.com` works. Anything that is
    # not a well-formed range is returned unchanged - including a plain
    # hostname, which is the overwhelming common case.
    def self.expand_host_range(entry : String) : Array(String)
      match = entry.match(/\A(.*)\[([^\[\]:]+):([^\[\]:]+)(?::([0-9]+))?\](.*)\z/)
      return [entry] unless match

      prefix, from, to, step_raw, suffix = match[1], match[2], match[3], match[4]?, match[5]
      step = (step_raw.try(&.to_i?) || 1)
      step = 1 if step < 1

      names = [] of String

      if (from_i = from.to_i?) && (to_i = to.to_i?)
        # Zero-padding comes from how the FIRST bound was written.
        width = from.starts_with?('0') ? from.size : 0
        value = from_i
        while value <= to_i
          rendered = width > 0 ? value.to_s.rjust(width, '0') : value.to_s
          names << "#{prefix}#{rendered}#{suffix}"
          value += step
        end
      elsif from.size == 1 && to.size == 1 && from[0].ascii_letter? && to[0].ascii_letter?
        value = from[0].ord
        while value <= to[0].ord
          names << "#{prefix}#{value.chr}#{suffix}"
          value += step
        end
      else
        return [entry]
      end

      names.empty? ? [entry] : names
    end

    # Parse host line from INI
    private def self.parse_host_line(line : String, group_name : String, inventory : Inventory)
      # Format: hostname key=value key=value
      #
      # Split the way real Ansible does - `shlex.split`, not a plain
      # whitespace split. Two things follow from that, both verified
      # against ansible-core 2.19.4: a quoted value may CONTAIN spaces
      # (`w1 motd='hello there'` is one token), and the quotes are
      # consumed by the splitter, so what reaches the value parser is
      # already unquoted. That second part is why `w1 port="6"` is the
      # INT 6 here while `port="6"` inside a [group:vars] block is the
      # STRING "6" - there the quotes survive into literal_eval, which
      # reads them as a Python string literal.
      parts = shlex_split(line)
      return if parts.empty?

      # A host entry may be a RANGE standing for several hosts -
      # `web[01:03]`, `n[1:3]`, `h[a:c]`, `x[01:10:3]`,
      # `srv[1:2].ex.com`. Previously the whole thing was taken as one
      # literal hostname, so an inventory using the ordinary
      # `web[01:03]` form defined a single host actually NAMED
      # "web[01:03]" and every real host in it was invisible.
      expand_host_range(parts[0]).each do |hostname|
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
      end

      hostname = parts[0]
      host = inventory.hosts[hostname]?
      return unless host

      # Special handling for ansible_host: don't modify host.name, but
      # the connection will use ansible_host from host vars directly.

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
              host.vars[key.to_s] = Vault.maybe_decrypt_json(Vault.yaml_value_to_json(value))

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
          group.vars[key.to_s] = Vault.maybe_decrypt_json(Vault.yaml_value_to_json(value))
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

    # Load group_vars/*.yml and host_vars/*.yml from directories adjacent
    # to the inventory file (its own directory, not the playbook's - a
    # simplification versus real Ansible, which checks both) and apply
    # them to matching hosts. Only a single group_vars/<name>.yml /
    # host_vars/<name>.yml file per name is supported, not the
    # directory-of-multiple-files style Ansible also allows
    # (group_vars/<name>/*.yml) - the common case, not full parity.
    #
    # Applied host_vars/<host> -> group_vars/<group> -> group_vars/all
    # order using set-if-absent (a host's vars already present - from an
    # inline inventory host line, or a higher-precedence file already
    # applied - are never overwritten), so the net precedence is: inline
    # host vars > host_vars file > group_vars file > (afterward, in
    # apply_group_vars) inline group vars. Real Ansible's actual
    # precedence has host_vars files outrank inline host vars too, but
    # group_vars/host_vars files and inline vars on the
    # very same key is a rare enough combination that this simpler,
    # documented approximation is a reasonable trade rather than
    # threading a second "was this explicitly inline" flag through Host.
    private def self.load_group_and_host_vars(inventory : Inventory, inventory_dir : String)
      group_vars_dir = File.join(inventory_dir, "group_vars")
      host_vars_dir = File.join(inventory_dir, "host_vars")

      # Set-if-absent (apply_vars_file) means whichever of these runs
      # *first* wins a given key, so highest-precedence goes first:
      # host_vars/<hostname> > group_vars/<group> > group_vars/all.
      inventory.hosts.each do |name, host|
        apply_vars_file([host], File.join(host_vars_dir, name))
      end

      inventory.groups.each do |group_name, group|
        next if group_name == "all"
        apply_vars_file(group.hosts.values, File.join(group_vars_dir, group_name))
      end

      apply_vars_file(inventory.hosts.values, File.join(group_vars_dir, "all"))
    end

    # Load base_path.yml (or .yaml) if it exists and apply its top-level
    # keys to every given host, skipping any key the host already has -
    # see load_group_and_host_vars for the precedence this establishes.
    private def self.apply_vars_file(hosts : Array(Host), base_path : String)
      path = {"#{base_path}.yml", "#{base_path}.yaml"}.find { |p| File.exists?(p) }
      return unless path

      begin
        yaml = YAML.parse(File.read(path))
      rescue ex : YAML::ParseException
        raise "Invalid YAML in #{path}: #{ex.message}"
      end
      return unless hash = yaml.as_h?

      hosts.each do |host|
        hash.each do |key, value|
          key_str = key.to_s
          next if host.vars.has_key?(key_str)

          json_value = Vault.maybe_decrypt_json(Vault.yaml_value_to_json(value))
          host.vars[key_str] = json_value

          case key_str
          when "ansible_user"
            host.user = json_value.as_s? || host.user
          when "ansible_port"
            host.port = json_value.as_i? || json_value.as_s?.try(&.to_i?) || host.port
          end
        end
      end
    end

    # Apply group variables to hosts
    private def self.apply_group_vars(inventory : Inventory)
      inventory.groups.each do |group_name, group|
        # `[all:vars]` applies to EVERY host in the inventory, not just
        # to hosts explicitly listed under an `[all]` section - which no
        # INI inventory ever writes, since membership of `all` is
        # implicit. The INI parser files each host under its own named
        # group (or `ungrouped`) and never under `all`, so this group's
        # own `hosts` is empty and its vars reached nobody: an
        # `[all:vars]` block - one of the most common things an
        # inventory contains - was silently ignored in its entirety.
        # Found while adding directory-inventory support (0.9.610),
        # where the same block additionally has to reach hosts defined
        # in a different file.
        if group_name == "all"
          inventory.hosts.each_value do |host|
            group.vars.each { |key, value| host.vars[key] ||= value }
          end
        end

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

    # Parse a value (attempt to infer type). Matches real Ansible's INI parser:
    # - Quoted values are always strings (no type inference).
    # - Unquoted `true`/`false`/`yes`/`no` → boolean.
    # - Unquoted integers/floats → numeric.
    # - Unquoted `null`/`None` (case-insensitive) or bare `~` → JSON null.
    # - Everything else → string.
    # POSIX `shlex.split`, enough of it for an inventory host line:
    # whitespace separates tokens; single quotes take everything
    # literally up to the next single quote; double quotes do the same
    # but honour backslash escapes; a backslash outside quotes escapes
    # the next character; and adjacent quoted and unquoted runs
    # concatenate into ONE token (`a"b"c` is `abc`, `\'it\'\'s\'` is
    # `its`), which is the behavior a naive "strip surrounding quotes"
    # approach gets wrong.
    private def self.shlex_split(line : String) : Array(String)
      tokens = [] of String
      current = String::Builder.new
      started = false
      index = 0

      while index < line.size
        char = line[index]

        case char
        when ' ', '\t'
          if started
            tokens << current.to_s
            current = String::Builder.new
            started = false
          end
        when '\''
          started = true
          index += 1
          while index < line.size && line[index] != '\''
            current << line[index]
            index += 1
          end
        when '"'
          started = true
          index += 1
          while index < line.size && line[index] != '"'
            if line[index] == '\\' && index + 1 < line.size
              index += 1
              current << line[index]
            else
              current << line[index]
            end
            index += 1
          end
        when '\\'
          started = true
          index += 1
          current << line[index] if index < line.size
        else
          started = true
          current << char
        end

        index += 1
      end

      tokens << current.to_s if started
      tokens
    end

    # An INI inventory value, typed exactly as real Ansible types it -
    # by running the raw text through Python's `ast.literal_eval` and
    # keeping the string when that raises. That is a narrower rule than
    # it looks, and the difference is not cosmetic:
    #
    #   True / False        -> bool        true / false / TRUE -> STRING
    #   None                -> null        none / null / ~     -> STRING
    #   3 / -7 / 1.5        -> number      yes / no / on / off -> STRING
    #   [1, 2] / {'k': 'v'} -> list/dict   anything else       -> STRING
    #
    # (Verified value by value against ansible-core 2.19.4, for both
    # `[group:vars]` blocks and inline host-line vars.)
    #
    # This engine previously treated `true`/`yes`/`no`/`false` as
    # booleans and left `[1, 2]` as text, which broke two things
    # silently. A `[all:vars] enabled=false` is the *string* "false" on
    # real Ansible - which is TRUTHY - so `when: enabled` there fails
    # the task outright under 2.19's strict conditionals ("Conditional
    # result (True) was derived from value of type 'str'"), where this
    # engine quietly took the false branch and skipped it. And a
    # list-valued inventory var was a string here, so `loop:` over it
    # iterated characters or nothing rather than its elements.
    #
    # Quoted values ("yes"/'yes') are strings with the quotes stripped,
    # which is literal_eval's own behavior for a quoted Python string.
    # Python tuples (`(1, 2)`) are deliberately NOT parsed - literal_eval
    # accepts them, but a tuple has no JSON representation and no
    # inventory in the corpus uses one; they stay strings.
    private def self.parse_value(value : String) : JSON::Any
      return JSON::Any.new(value) if value.empty?

      if value.size >= 2 &&
         ((value.starts_with?('"') && value.ends_with?('"')) ||
         (value.starts_with?('\'') && value.ends_with?('\'')))
        return JSON::Any.new(value[1..-2])
      end

      # Case-SENSITIVE: Python knows `True`, not `true`.
      case value
      when "True"  then return JSON::Any.new(true)
      when "False" then return JSON::Any.new(false)
      when "None"  then return JSON::Any.new(nil)
      end

      if int_value = python_int(value)
        return JSON::Any.new(int_value)
      end

      # Floats are laxer than ints in Python: `01.5` is a perfectly good
      # float literal even though `0123` is not a good int one. Guarded
      # on the presence of a `.`/exponent so a rejected int literal
      # (`0123`) cannot slip through here as a float.
      if value.matches?(/\A[+-]?(?:\d[\d_]*)?(?:\.\d[\d_]*)?(?:[eE][+-]?\d[\d_]*)?\z/) &&
         (value.includes?('.') || value.includes?('e') || value.includes?('E'))
        if float_value = value.delete('_').to_f?
          return JSON::Any.new(float_value)
        end
      end

      if (value.starts_with?('[') && value.ends_with?(']')) ||
         (value.starts_with?('{') && value.ends_with?('}'))
        if parsed = python_literal_to_json(value)
          return parsed
        end
      end

      JSON::Any.new(value)
    end

    # Python's own decimal-integer literal rule, which is stricter than
    # `String#to_i64?`: a leading zero may only be followed by more
    # zeros (`0` and `00` are ints, `0123` is a SyntaxError and stays a
    # string - which is exactly how a zero-padded value like an
    # `id=0123` survives as text on real Ansible), and `_` is a legal
    # digit separator (`1_000` is 1000). Verified against ansible-core
    # 2.19.4 over all six shapes.
    private def self.python_int(value : String) : Int64?
      return nil unless value.matches?(/\A[+-]?(?:0(?:_?0)*|[1-9](?:_?[0-9])*)\z/)
      value.delete('_').to_i64?
    end

    # Best-effort `literal_eval` for the container literals an inventory
    # actually carries: rewrites Python's single-quoted strings and
    # True/False/None into their JSON spellings and hands the result to
    # the JSON parser. Returns nil when that fails, which lands the
    # caller on literal_eval's own fallback - the untouched string.
    private def self.python_literal_to_json(value : String) : JSON::Any?
      converted = String.build do |str|
        index = 0
        while index < value.size
          char = value[index]
          case char
          when '\''
            # A single-quoted Python string becomes a JSON string; inner
            # double quotes have to be escaped on the way.
            index += 1
            str << '"'
            while index < value.size && value[index] != '\''
              str << "\\" if value[index] == '"' || value[index] == '\\'
              str << value[index]
              index += 1
            end
            str << '"'
          when '"'
            str << '"'
            index += 1
            while index < value.size && value[index] != '"'
              str << "\\" if value[index] == '\\'
              str << value[index]
              index += 1
            end
            str << '"'
          else
            if value[index, 4]? == "True"
              str << "true"
              index += 3
            elsif value[index, 5]? == "False"
              str << "false"
              index += 4
            elsif value[index, 4]? == "None"
              str << "null"
              index += 3
            else
              str << char
            end
          end
          index += 1
        end
      end

      JSON.parse(converted)
    rescue
      nil
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
        "hosts"  => inventory.hosts.size,
        "groups" => inventory.groups.size - 2, # Exclude 'all' and 'ungrouped'
        "vars"   => inventory.groups.sum { |_, g| g.vars.size },
      }
    end
  end
end
