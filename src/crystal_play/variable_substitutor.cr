require "json"

module CrystalPlay
  # Variable Substitution Engine
  # Handles Ansible-style {{ variable }} substitution
  # Supports:
  # - Simple variables: {{ myvar }}
  # - Nested variables: {{ user.name }}
  # - Dictionary access: {{ users['admin'] }}
  # - List access: {{ items[0] }}
  # - Filters: {{ myvar | default('value') }}
  # - Magic variables: {{ inventory_hostname }}, {{ ansible_hostname }}
  
  class VariableSubstitutor
    # Storage for all variables
    @vars : Hash(String, JSON::Any)
    @host_name : String
    @facts : Hash(String, JSON::Any)
    
    def initialize(vars : Hash(String, String | JSON::Any) = {} of String => String | JSON::Any, 
                   host_name : String = "localhost",
                   facts : Hash(String, JSON::Any) = {} of String => JSON::Any)
      @host_name = host_name
      @facts = facts
      
      # Convert all vars to JSON::Any for consistent handling
      @vars = Hash(String, JSON::Any).new
      vars.each do |key, value|
        @vars[key] = case value
        when JSON::Any
          value
        when String
          JSON::Any.new(value)
        else
          JSON.parse(value.to_json)
        end
      end
      
      # Add magic variables
      add_magic_variables
    end
    
    # Add Ansible magic variables
    private def add_magic_variables
      @vars["inventory_hostname"] = JSON::Any.new(@host_name)
      @vars["ansible_hostname"] = JSON::Any.new(@host_name)
      @vars["ansible_host"] = JSON::Any.new(@host_name)
      
      # Add facts if available
      @facts.each do |key, value|
        @vars["ansible_#{key}"] = value
      end
    end
    
    # Main substitution method
    # Substitutes all {{ var }} patterns in a string
    def substitute(text : String) : String
      # Handle simple case - no substitutions needed
      return text unless text.includes?("{{")
      
      result = text.dup
      
      # Match {{ ... }} patterns (non-greedy)
      # Supports nested braces in some cases
      pattern = /\{\{([^}]+)\}\}/
      
      loop do
        match = result.match(pattern)
        break unless match
        
        full_match = match[0]
        expression = match[1].strip
        
        # Evaluate the expression
        value = evaluate_expression(expression)
        
        # Replace in result
        result = result.sub(full_match, value)
      end
      
      result
    end
    
    # Substitute in a hash (recursively)
    def substitute_hash(hash : Hash(String, String)) : Hash(String, String)
      result = Hash(String, String).new
      
      hash.each do |key, value|
        result[substitute(key)] = substitute(value)
      end
      
      result
    end
    
    # Substitute in an array
    def substitute_array(array : Array(String)) : Array(String)
      array.map { |item| substitute(item) }
    end
    
    # Evaluate a variable expression
    # Handles: simple vars, nested access, filters
    private def evaluate_expression(expr : String) : String
      # Check for filters (|)
      if expr.includes?("|")
        return evaluate_with_filter(expr)
      end
      
      # Check for dictionary/list access
      if expr.includes?("[")
        return evaluate_indexed_access(expr)
      end
      
      # Check for nested access (.)
      if expr.includes?(".")
        return evaluate_nested_access(expr)
      end
      
      # Simple variable lookup
      lookup_variable(expr)
    end
    
    # Evaluate expression with filter
    # Example: myvar | default('value')
    private def evaluate_with_filter(expr : String) : String
      parts = expr.split("|", 2)
      var_expr = parts[0].strip
      filter_expr = parts[1].strip
      
      # Get the variable value
      value = if var_expr.includes?("[") || var_expr.includes?(".")
        evaluate_expression(var_expr)
      else
        lookup_variable(var_expr)
      end
      
      # Apply filter
      apply_filter(value, filter_expr)
    end
    
    # Apply a filter to a value
    private def apply_filter(value : String, filter_expr : String) : String
      # Parse filter name and arguments
      if match = filter_expr.match(/^(\w+)\s*\((.+)\)$/)
        filter_name = match[1]
        filter_args = match[2]
      else
        filter_name = filter_expr
        filter_args = ""
      end
      
      case filter_name
      when "default"
        # default('value') - return value if variable is undefined/empty
        if value.empty? || value == "undefined"
          parse_filter_arg(filter_args)
        else
          value
        end
      when "upper"
        value.upcase
      when "lower"
        value.downcase
      when "capitalize"
        value.capitalize
      when "title"
        value.split.map(&.capitalize).join(" ")
      when "trim", "strip"
        value.strip
      when "length"
        value.size.to_s
      when "replace"
        # replace('old', 'new')
        args = parse_filter_args(filter_args)
        if args.size >= 2
          value.gsub(args[0], args[1])
        else
          value
        end
      when "split"
        # split(',') - return first element for simplicity
        delimiter = parse_filter_arg(filter_args)
        value.split(delimiter).first? || value
      else
        # Unknown filter - return value as-is
        value
      end
    end
    
    # Parse filter argument (remove quotes)
    private def parse_filter_arg(arg : String) : String
      arg = arg.strip
      if arg.starts_with?("'") && arg.ends_with?("'")
        arg[1..-2]
      elsif arg.starts_with?('"') && arg.ends_with?('"')
        arg[1..-2]
      else
        arg
      end
    end
    
    # Parse multiple filter arguments
    private def parse_filter_args(args : String) : Array(String)
      # Simple parser - split by comma, handle quotes
      result = [] of String
      current = ""
      in_quotes = false
      quote_char = ' '
      
      args.each_char do |char|
        case char
        when '\'', '"'
          if in_quotes && char == quote_char
            in_quotes = false
          elsif !in_quotes
            in_quotes = true
            quote_char = char
          else
            current += char
          end
        when ','
          if in_quotes
            current += char
          else
            result << current.strip
            current = ""
          end
        else
          current += char
        end
      end
      
      result << current.strip unless current.empty?
      result.map { |arg| parse_filter_arg(arg) }
    end
    
    # Evaluate indexed access
    # Example: mylist[0], mydict['key']
    private def evaluate_indexed_access(expr : String) : String
      # Match pattern: varname[index]
      if match = expr.match(/^([^\[]+)\[([^\]]+)\]/)
        var_name = match[1].strip
        index_expr = match[2].strip
        
        # Look up the variable
        var_value = @vars[var_name]?
        return "undefined" unless var_value
        
        # Parse index (could be number or string)
        index = if index_expr.starts_with?("'") || index_expr.starts_with?('"')
          parse_filter_arg(index_expr)
        else
          index_expr.to_i? || index_expr
        end
        
        # Access the value
        case var_value.raw
        when Array
          var_value[index.as(Int32)]?.try(&.to_s) || "undefined"
        when Hash
          var_value[index.to_s]?.try(&.to_s) || "undefined"
        else
          "undefined"
        end
      else
        "undefined"
      end
    end
    
    # Evaluate nested access
    # Example: user.name, config.database.host
    private def evaluate_nested_access(expr : String) : String
      parts = expr.split(".")
      current = @vars[parts[0]]?
      
      return "undefined" unless current
      
      # Navigate through nested structure
      parts[1..-1].each do |part|
        case current.raw
        when Hash
          current = current[part]?
          return "undefined" unless current
        else
          return "undefined"
        end
      end
      
      current.to_s
    end
    
    # Simple variable lookup
    private def lookup_variable(name : String) : String
      name = name.strip
      
      # Check if variable exists
      if @vars.has_key?(name)
        value = @vars[name]
        
        # Convert to string based on type
        case value.raw
        when String
          value.as_s
        when Int64, Int32
          value.as_i.to_s
        when Float64
          value.as_f.to_s
        when Bool
          value.as_bool.to_s
        when Array
          value.to_json
        when Hash
          value.to_json
        when Nil
          ""
        else
          value.to_s
        end
      else
        # Return undefined marker (will be handled by filters)
        "undefined"
      end
    end
    
    # Set a variable
    def set_variable(name : String, value : String | JSON::Any)
      @vars[name] = case value
      when JSON::Any
        value
      else
        JSON::Any.new(value)
      end
    end
    
    # Get all variables
    def get_vars : Hash(String, JSON::Any)
      @vars
    end
    
    # Check if variable exists
    def has_variable?(name : String) : Bool
      @vars.has_key?(name)
    end
  end
end
