require "process"
require "file_utils"

# Local Executor - Executes commands locally without SSH
# Used when ansible_connection=local or host is localhost with local connection
module CrystalPlay
  class LocalExecutor
    # Execute command locally
    def self.exec(command : String) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      
      begin
        # Build the bash command
        # We need to properly escape the command for shell execution
        # Using shell: true to let the shell handle the parsing
        bash_cmd = "/bin/bash -c '#{command.gsub("'", "'\\''")}'"
        
        process = Process.run(
          bash_cmd,
          shell: true,
          output: stdout,
          error: stderr
        )
        
        {
          exit_code: process.exit_code,
          stdout: stdout.to_s,
          stderr: stderr.to_s
        }
      rescue ex
        {
          exit_code: 1,
          stdout: "",
          stderr: "Local execution failed: #{ex.message}"
        }
      end
    end
    
    # Copy file locally
    def self.copy_file(src : String, dest : String)
      FileUtils.cp(src, dest)
    end
    
    # Check if file exists
    def self.file_exists?(path : String) : Bool
      File.exists?(path)
    end
    
    # Check if directory exists
    def self.dir_exists?(path : String) : Bool
      Dir.exists?(path)
    end
  end
end
