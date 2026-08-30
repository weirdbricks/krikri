require "option_parser"
require "./vault"

module Krikri
  # VaultCli - `krikri-playbook vault <subcommand> ...`, matching real
  # `ansible-vault`'s CLI shape for the common, non-interactive
  # subcommands. `create`/`edit` (which launch $EDITOR) aren't implemented.
  module VaultCli
    def self.run(args : Array(String))
      subcommand = args[0]?
      unless subcommand
        usage
        exit 1
      end

      rest = args[1..]

      case subcommand
      when "encrypt"        then encrypt_command(rest)
      when "decrypt"        then decrypt_command(rest)
      when "view"           then view_command(rest)
      when "encrypt_string" then encrypt_string_command(rest)
      when "rekey"          then rekey_command(rest)
      when "-h", "--help"
        usage
      else
        STDERR.puts "Unknown vault subcommand: #{subcommand}"
        usage
        exit 1
      end
    rescue ex : Vault::Error
      STDERR.puts "ERROR! #{ex.message}"
      exit 1
    rescue ex : File::NotFoundError
      STDERR.puts "ERROR! #{ex.message}"
      exit 1
    end

    private def self.usage
      puts "Usage: krikri-playbook vault {encrypt|decrypt|view|encrypt_string|rekey} [options] [file ...]"
      puts ""
      puts "Examples:"
      puts "  krikri-playbook vault encrypt --vault-password-file pass.txt secrets.yml"
      puts "  krikri-playbook vault decrypt --vault-password-file pass.txt secrets.yml"
      puts "  krikri-playbook vault view --vault-password-file pass.txt secrets.yml"
      puts "  krikri-playbook vault encrypt_string --vault-password-file pass.txt --name db_password 'hunter2'"
      puts "  krikri-playbook vault rekey --vault-password-file old.txt --new-vault-password-file new.txt secrets.yml"
    end

    private def self.read_password_file(path : String) : String
      File.read(path).strip
    end

    # Public: also used directly by krikri-playbook.cr's --ask-vault-pass for
    # running a playbook (not just the `vault` subcommands here).
    def self.prompt_password(prompt : String = "Vault password: ") : String
      print prompt
      STDOUT.flush

      echo_disabled = begin
        Process.run("stty", ["-echo"], input: Process::Redirect::Inherit, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit).success?
      rescue
        false
      end

      password = STDIN.gets.try(&.chomp) || ""

      if echo_disabled
        Process.run("stty", ["echo"], input: Process::Redirect::Inherit, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit) rescue nil
      end
      puts

      password
    end

    private def self.resolve_password(vault_password_file : String?) : String
      vault_password_file ? read_password_file(vault_password_file) : prompt_password
    end

    private def self.encrypt_command(args : Array(String))
      vault_password_file, output_path, files = parse_file_args(args)

      if files.empty?
        STDERR.puts "Usage: krikri-playbook vault encrypt [--vault-password-file FILE] [--output FILE] FILE ..."
        exit 1
      end

      password = resolve_password(vault_password_file)

      files.each do |file|
        content = File.read(file)
        if Vault.encrypted?(content)
          puts "#{file} is already encrypted"
          next
        end

        File.write(output_path || file, Vault.encrypt(content, password))
        puts "Encryption successful"
      end
    end

    private def self.decrypt_command(args : Array(String))
      vault_password_file, output_path, files = parse_file_args(args)

      if files.empty?
        STDERR.puts "Usage: krikri-playbook vault decrypt [--vault-password-file FILE] [--output FILE] FILE ..."
        exit 1
      end

      password = resolve_password(vault_password_file)

      files.each do |file|
        content = File.read(file)
        File.write(output_path || file, Vault.decrypt(content, password))
        puts "Decryption successful"
      end
    end

    private def self.view_command(args : Array(String))
      vault_password_file, _output_path, files = parse_file_args(args)

      if files.size != 1
        STDERR.puts "Usage: krikri-playbook vault view [--vault-password-file FILE] FILE"
        exit 1
      end

      password = resolve_password(vault_password_file)
      puts Vault.decrypt(File.read(files[0]), password)
    end

    private def self.encrypt_string_command(args : Array(String))
      vault_password_file = nil
      name = nil
      strings = [] of String

      OptionParser.parse(args) do |parser|
        parser.on("--vault-password-file=FILE", "Vault password file") { |file| vault_password_file = file }
        parser.on("--name=NAME", "Variable name to use in the output") { |value| name = value }
        parser.unknown_args { |extra| strings.concat(extra) }
      end

      unless name
        STDERR.puts "Usage: krikri-playbook vault encrypt_string [--vault-password-file FILE] --name VAR_NAME 'plaintext'"
        exit 1
      end

      if strings.empty?
        STDERR.puts "Usage: krikri-playbook vault encrypt_string [--vault-password-file FILE] --name VAR_NAME 'plaintext'"
        exit 1
      end

      password = resolve_password(vault_password_file)
      encrypted = Vault.encrypt(strings.join(" "), password)

      puts "#{name}: !vault |"
      encrypted.each_line { |line| puts "          #{line}" unless line.empty? }
    end

    private def self.rekey_command(args : Array(String))
      vault_password_file = nil
      new_vault_password_file = nil
      files = [] of String

      OptionParser.parse(args) do |parser|
        parser.on("--vault-password-file=FILE", "Current vault password file") { |file| vault_password_file = file }
        parser.on("--new-vault-password-file=FILE", "New vault password file") { |file| new_vault_password_file = file }
        parser.unknown_args { |extra| files.concat(extra) }
      end

      if files.empty?
        STDERR.puts "Usage: krikri-playbook vault rekey [--vault-password-file FILE] --new-vault-password-file FILE FILE ..."
        exit 1
      end

      old_password = resolve_password(vault_password_file)
      new_password = if file = new_vault_password_file
                       read_password_file(file)
                     else
                       prompt_password("New vault password: ")
                     end

      files.each do |target_file|
        plaintext = Vault.decrypt(File.read(target_file), old_password)
        File.write(target_file, Vault.encrypt(plaintext, new_password))
        puts "Rekey successful"
      end
    end

    # Shared --vault-password-file/--output/positional-files parsing for
    # encrypt/decrypt/view.
    private def self.parse_file_args(args : Array(String)) : {String?, String?, Array(String)}
      vault_password_file = nil
      output_path = nil
      files = [] of String

      OptionParser.parse(args) do |parser|
        parser.on("--vault-password-file=FILE", "Vault password file") { |file| vault_password_file = file }
        parser.on("--output=FILE", "Output file (default: in place)") { |file| output_path = file }
        parser.unknown_args { |extra| files.concat(extra) }
      end

      {vault_password_file, output_path, files}
    end
  end
end
