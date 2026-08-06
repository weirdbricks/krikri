require "json"
require "digest/md5"
require "crinja"
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
