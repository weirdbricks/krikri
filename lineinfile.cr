#!/usr/bin/env crystal

# Lineinfile Plugin for Crystal Play
# Manages lines in text files (Ansible-compatible)
# 
# Supports:
# - Ensure line exists (state: present)
# - Remove line (state: absent)
# - Replace line matching regex
# - Insert before/after pattern
# - Backreferences in replacement
# - Create file if missing (create: yes)
# - Backup before changes (backup: yes)

require "json"
require "file_utils"

# Parse command line arguments
config = JSON.parse(ARGV[0])

path = config["path"].as_s
line = config["line"]?.try(&.as_s)
regexp = config["regexp"]?.try(&.as_s)
state = config["state"]?.try(&.as_s) || "present"
create = config["create"]?.try(&.as_bool) || false
backup = config["backup"]?.try(&.as_bool) || false
insertafter = config["insertafter"]?.try(&.as_s)
insertbefore = config["insertbefore"]?.try(&.as_s)
backrefs = config["backrefs"]?.try(&.as_bool) || false
check_mode = config["check_mode"]?.try(&.as_bool) || false

# Validate parameters
if state == "present" && !line
  puts({
    "failed" => true,
    "msg" => "line parameter required when state=present"
  }.to_json)
  exit(1)
end

if state == "absent" && !regexp && !line
  puts({
    "failed" => true,
    "msg" => "regexp or line parameter required when state=absent"
  }.to_json)
  exit(1)
end

# Check if file exists
file_exists = File.exists?(path)

# Handle create parameter
if !file_exists
  if !create
    puts({
      "failed" => true,
      "msg" => "File #{path} does not exist. Use create: yes to create it."
    }.to_json)
    exit(1)
  end
  
  # Create file
  if !check_mode
    # Create parent directory if needed
    dir = File.dirname(path)
    Dir.mkdir_p(dir) unless Dir.exists?(dir)
    
    # Create empty file
    File.write(path, "")
  end
  
  file_exists = true
end

# Read current content
original_content = file_exists ? File.read(path) : ""
lines = original_content.split("\n", -1)

# Remove trailing empty string if file doesn't end with newline
lines.pop if lines.size > 0 && lines.last.empty? && !original_content.ends_with?("\n")

changed = false
new_lines = lines.dup

# Helper function to check if line matches regexp
def matches_regexp?(line_text : String, pattern : String?) : Bool
  return false unless pattern
  begin
    regex = Regex.new(pattern)
    return !!(line_text =~ regex)
  rescue
    return false
  end
end

# Helper function to check if lines are equal (for exact matching)
def lines_equal?(line1 : String, line2 : String) : Bool
  line1.strip == line2.strip
end

# State: absent - Remove matching lines
if state == "absent"
  new_lines = [] of String
  
  lines.each do |existing_line|
    should_remove = false
    
    # Check if line matches regexp
    if regexp
      should_remove = matches_regexp?(existing_line, regexp)
    elsif line
      # Exact match
      should_remove = lines_equal?(existing_line, line.not_nil!)
    end
    
    if !should_remove
      new_lines << existing_line
    else
      changed = true
    end
  end
end

# State: present - Ensure line exists
if state == "present"
  line_exists = false
  line_index = -1
  
  # Check if line already exists (exact or via regexp)
  lines.each_with_index do |existing_line, index|
    if regexp
      # Check via regexp
      if matches_regexp?(existing_line, regexp)
        line_index = index
        
        # With backrefs, perform substitution
        if backrefs
          begin
            regex = Regex.new(regexp)
            substituted = existing_line.gsub(regex, line.not_nil!)
            
            if existing_line != substituted
              new_lines[index] = substituted
              changed = true
            end
            line_exists = true
          rescue ex
            # Regex error
            puts({
              "failed" => true,
              "msg" => "Invalid regexp: #{ex.message}"
            }.to_json)
            exit(1)
          end
        else
          # Replace entire line
          if existing_line != line
            new_lines[index] = line.not_nil!
            changed = true
          end
          line_exists = true
        end
        break
      end
    else
      # Exact match
      if lines_equal?(existing_line, line.not_nil!)
        line_exists = true
        break
      end
    end
  end
  
  # If line doesn't exist, add it
  if !line_exists
    # Determine where to insert
    insert_index = -1
    
    if insertafter
      if insertafter == "EOF" || insertafter == "END"
        # Insert at end
        insert_index = new_lines.size
      else
        # Find line matching insertafter pattern
        new_lines.each_with_index do |existing_line, index|
          if matches_regexp?(existing_line, insertafter)
            insert_index = index + 1
            break
          end
        end
        
        # If pattern not found, insert at end
        if insert_index == -1
          insert_index = new_lines.size
        end
      end
    elsif insertbefore
      if insertbefore == "BOF" || insertbefore == "BEGIN"
        # Insert at beginning
        insert_index = 0
      else
        # Find line matching insertbefore pattern
        new_lines.each_with_index do |existing_line, index|
          if matches_regexp?(existing_line, insertbefore)
            insert_index = index
            break
          end
        end
        
        # If pattern not found, insert at end
        if insert_index == -1
          insert_index = new_lines.size
        end
      end
    else
      # No insertion point specified - append at end
      insert_index = new_lines.size
    end
    
    # Insert the line
    if insert_index >= 0
      new_lines.insert(insert_index, line.not_nil!)
      changed = true
    end
  end
end

# Generate new content
new_content = new_lines.join("\n")

# Add final newline if original had one or if file is being created
if original_content.ends_with?("\n") || (!file_exists && new_lines.size > 0)
  new_content += "\n"
end

# Create backup if requested and file changed
backup_file = ""
if backup && changed && file_exists && !check_mode
  timestamp = Time.local.to_s("%Y%m%d-%H%M%S")
  backup_file = "#{path}.#{timestamp}.bak"
  File.copy(path, backup_file)
end

# Write changes (unless check mode)
if changed && !check_mode
  File.write(path, new_content)
end

# Build diff for diff mode
diff = nil
if changed && (config["diff"]?.try(&.as_bool) || false)
  diff = {
    "before" => original_content,
    "after" => new_content
  }
end

# Return result
result = Hash(String, JSON::Any::Type).new
result["changed"] = changed
result["failed"] = false
result["msg"] = changed ? "Line modified" : "Line already present"
result["path"] = path
result["line"] = line
result["state"] = state

result["backup_file"] = backup_file if !backup_file.empty?
if diff
  # Assign diff values directly - they're strings which are JSON::Any::Type
  result["diff_before"] = diff["before"]
  result["diff_after"] = diff["after"]
end

puts result.to_json
