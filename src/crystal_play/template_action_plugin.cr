require "json"
require "digest/md5"
require "crinja"
require "./jinja_filters"
require "./base_action_plugin"
# For the shared JSON::Any -> Crinja::Value converter (this plugin keeps
# its own Crinja environment - see that method's comment for why).
require "./variable_substitutor/crinja_renderer"

module CrystalPlay
  # Template Action Plugin
  # Runs on CONTROLLER to read and render Jinja2 templates
  # Then sends rendered content to remote host
  
  class TemplateActionPlugin < ActionPlugin
    def execute : ActionResult
      # Get source template path
      src = @params["src"]?
      unless src
        return ActionResult.failure("Missing required parameter: src")
      end
      
      # Check if template file exists on CONTROLLER
      unless File.exists?(src)
        return ActionResult.failure("Template file not found on controller: #{src}")
      end
      
      # Read template content
      begin
        template_content = File.read(src)
      rescue ex
        return ActionResult.failure("Failed to read template file: #{ex.message}")
      end
      
      # Render template on CONTROLLER
      rendered_content = render_template(template_content, src)
      unless rendered_content
        return ActionResult.failure("Failed to render template")
      end
      
      # Calculate MD5 of rendered content
      content_md5 = Digest::MD5.hexdigest(rendered_content)
      
      # Modify params to send rendered CONTENT to remote instead of template path
      # The remote plugin will receive the rendered content, not the template
      modified_params = @params.dup
      modified_params.delete("src")  # Remove src parameter
      modified_params["content"] = rendered_content  # Add rendered content
      modified_params["_rendered_from_template"] = src  # Track for debugging
      modified_params["_content_checksum"] = content_md5  # For idempotency
      
      ActionResult.success(modified_params, changed: false)
    end
    
    # Render Jinja2 template with variables
    private def render_template(template_content : String, template_path : String) : String?
      begin
        # Crinja 0.9.0 cannot parse Jinja2's inline conditional expression
        # `{{ A if C else B }}`. Real Ansible supports it and real roles
        # (dev-sec os_hardening's login.defs and ufw templates) use it, so
        # rewrite the idiomatic form into the ternary filter we provide
        # (`{{ C | ternary(A, B) }}`) before Crinja sees it. Only the
        # literal `X if C else Y` shape is rewritten; `{% if %}` blocks are
        # left untouched.
        template_content = rewrite_inline_ternaries(template_content)

        # Create Crinja environment
        env = Crinja.new
        
        # Configure Crinja to match Ansible defaults
        trim_blocks = is_true?(@params["trim_blocks"]?, default: true)
        lstrip_blocks = is_true?(@params["lstrip_blocks"]?, default: false)
        
        env.config.trim_blocks = trim_blocks
        env.config.lstrip_blocks = lstrip_blocks
        
        # Prepare template variables
        template_vars = prepare_template_vars
        
        # Add Ansible-specific variables
        template_vars["ansible_managed"] = Crinja::Value.new("Ansible managed")
        template_vars["template_host"] = Crinja::Value.new(@host.name)
        template_vars["template_path"] = Crinja::Value.new(template_path)
        template_vars["template_fullpath"] = Crinja::Value.new(File.expand_path(template_path))
        template_vars["template_run_date"] = Crinja::Value.new(Time.utc.to_s("%Y-%m-%d %H:%M:%S UTC"))
        
        # Render template
        template = env.from_string(template_content)
        rendered = template.render(template_vars)
        
        # Ensure rendered content ends with newline (matches Ansible behavior and file conventions)
        # This prevents idempotency issues with heredoc writes that add trailing newlines
        rendered += "\n" unless rendered.ends_with?("\n")
        
        return rendered
      rescue
        return nil
      end
    end

    # Rewrites Jinja2 inline conditional expressions `{{ A if C else B }}`
    # into the Crinja-parseable `{{ C | ternary(A, B) }}` form. This is
    # real Jinja2 (used by dev-sec os_hardening), which Crinja 0.9.0 cannot
    # parse. Only `{{ }}` expression blocks are touched; `{% %}` statement
    # blocks are left as-is.
    #
    # Regex-based (not manual char indexing): matches a `{{ ... }}` block
    # and rewrites an inline ` A  if  C  else  B ` ternary within it. Each
    # match keeps the ` if ` / ` else ` as the top-level separator, so an
    # operand that is itself a parenthesized ternary (`(B if C2 else D)`)
    # is handled naturally by the nested `( ... )` captures.
    INLINE_TERNARY = /
      \{\{                          # opening {{
      (                             # capture the whole expression
        (?:[^}]*?)                 # lazy: up to the ternary
        \s+if\s+                  # the ` if ` keyword
        (?:[^}]*?)                 # condition (lazy)
        \s+else\s+                # the ` else ` keyword
        (?:[^}]*?)                 # else branch (lazy)
      )
      \}\}                        # closing }}
    /x

    # Method-call `.join(` form that real Jinja2 permits but Crinja's
    # parser rejects: `{{ "SEP".join(LIST) }}` is the standard `sep.join(list)`
    # idiom (dev-sec os_hardening's securetty template uses it). Rewritten
    # into the equivalent `LIST | join("SEP")` filter, which Crinja supports.
    # $1 = the sep string literal, $2 = the list expression being joined.
    JOIN_METHOD = /("(?:[^"\\]|\\.)*")\s*\.join\(\s*([^)]*?)\s*\)/

    private def rewrite_inline_ternaries(template : String) : String
      loop do
        once = template
        # Rewrite inline ternaries first.
        once = once.gsub(INLINE_TERNARY) do
          rewrite_ternary_expr($1)
        end
        # Then rewrite `.join(` method calls to the join filter.
        once = once.gsub(JOIN_METHOD) do
          "#{$2} | join(#{$1})"
        end
        break if once == template
        template = once
      end
      template
    end

    # Rewrites a single expression's `A if C else B` into `C | ternary(A, B)`.
    # Requires the literal ` if ` and ` else ` tokens present in *expr*.
    private def rewrite_ternary_expr(expr : String) : String
      # Split on the top-level ` if ` and ` else ` (guarding quotes/parens
      # via a small scan). Uses a manual scan rather than the regex above
      # because a ternary may be nested and we want the *last* ` else `.
      if_idx = index_of_token(expr, " if ")
      return expr unless if_idx >= 0
      else_idx = index_of_token_from(expr, " else ", if_idx)
      return expr unless else_idx >= 0

      then_part = expr[0...if_idx].strip
      cond_part = expr[if_idx + 4...else_idx].strip
      else_part = expr[else_idx + 6..].strip

      "#{cond_part} | ternary(#{then_part}, #{else_part})"
    end

    # Index of the first occurrence of *token* (outside quotes and at
    # paren depth 0), or -1. The token must be preceded/followed by a
    # non-identifier char so `elif`/`elseif` style keywords can't match.
    private def index_of_token(str : String, token : String) : Int32
      index_of_token_from(str, token, 0)
    end

    private def index_of_token_from(str : String, token : String, from : Int32) : Int32
      depth = 0
      in_single = false
      in_double = false
      j = from
      while j <= str.size - token.size
        c = str[j]
        if in_single
          in_single = false if c == '\''
        elsif in_double
          in_double = false if c == '"'
        else
          case c
          when '\'' then in_single = true
          when '"'  then in_double = true
          when '('  then depth += 1
          when ')'  then depth -= 1
          else
            if depth == 0 && str[j, token.size] == token
              return j
            end
          end
        end
        j += 1
      end
      -1
    end


    # Prepare variables for template rendering
    private def prepare_template_vars : Hash(String, Crinja::Value)
      vars = Hash(String, Crinja::Value).new
      
      # Add all vars
      @vars.each do |key, value|
        vars[key] = VariableSubstitutor::CrinjaRenderer.json_any_to_crinja_value(value)
      end
      
      # Add host information
      vars["inventory_hostname"] = Crinja::Value.new(@host.name)
      vars["ansible_hostname"] = Crinja::Value.new(@host.name)
      vars["ansible_host"] = Crinja::Value.new(@host.name)
      
      vars
    end
    
    
    # Helper: Check if parameter is truthy
    private def is_true?(value : String?, default : Bool = false) : Bool
      return default unless value
      ["true", "yes", "1", "on"].includes?(value.downcase)
    end
  end
end
