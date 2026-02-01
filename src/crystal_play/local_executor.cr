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
        process = Process.new(
          "/bin/sh",
          ["-c", command],
          output: stdout,
          error: stderr
        )
        
        status = process.wait
        
        {
          exit_code: status.exit_code,
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
