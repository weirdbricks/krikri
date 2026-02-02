require "json"

module CrystalPlay
  module VariableSubstitutor
    # FilterEngine - Applies Ansible-style filters to values
    # Supports: default, upper, lower, capitalize, title, trim, length, replace, split
    class FilterEngine
      
      # Apply a filter to a value
      # Example: myvar | default('value')
      def apply(value : String, filter_expr : String) : String
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
      
      # Parse a single filter argument (remove quotes)
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
    end
  end
end
