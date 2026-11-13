require "process"

module Krikri
  # Bounds ONE playbook run's wall clock when KRIKRI_PLAYBOOK_DEADLINE_SECONDS
  # is set. scripts/minitest.sh sets it for the suite; an ordinary CLI run
  # never does, so Ansible-parity output is untouched.
  #
  # A spec's playbook that never finished froze its whole test shard: the
  # specs' Process.run blocks until the child exits AND every holder of the
  # captured pipes closes them (Crystal's Process#wait drains before
  # reaping, and a grandchild that inherited stdout keeps the pipe open),
  # while nothing in the engine bounds a local plugin run or such a
  # grandchild. Issue #1189: three shards went silent for 470s with their
  # playbooks alive at 0.2% CPU.
  #
  # On expiry this reports where this process and every process below it
  # are blocked, kills that tree (so the caller's pipes close and its
  # Process#wait returns) and exits 124 - a failing spec naming the
  # playbook, instead of a suite that hangs until MINITEST_TIMEOUT.
  module PlaybookDeadline
    def self.install : Nil
      seconds = (ENV["KRIKRI_PLAYBOOK_DEADLINE_SECONDS"]? || "").to_i? || 0
      return if seconds <= 0
      spawn do
        sleep seconds.seconds
        report(seconds)
        kill_tree(LibC.getpid)
        STDERR.flush
        STDOUT.flush
        exit 124
      end
    end

    private def self.report(seconds : Int32) : Nil
      me = LibC.getpid
      STDERR.puts "krikri-playbook: still running after #{seconds}s (KRIKRI_PLAYBOOK_DEADLINE_SECONDS); " \
                  "killing this run and everything it spawned"
      STDERR.puts "--- threads of pid #{me} (state / wchan / syscall)"
      thread_lines(me)
      descendants = [] of Int32
      collect_descendants(me, descendants)
      STDERR.puts "--- #{descendants.size} child process(es)"
      descendants.each do |pid|
        STDERR.puts "--- pid #{pid}: #{cmdline(pid)}"
        thread_lines(pid)
      end
    rescue ex
      STDERR.puts "krikri-playbook: deadline report failed: #{ex.message}"
    end

    private def self.thread_lines(pid : Int32) : Nil
      Dir.glob("/proc/#{pid}/task/[0-9]*").each do |task|
        state = begin
          stat = read_file(File.join(task, "stat")) || ""
          rest = stat[(stat.rindex(')') || 0) + 2..]? || stat
          rest.split(' ').first? || "?"
        end
        wchan = (read_file(File.join(task, "wchan")) || "").strip
        syscall = (read_file(File.join(task, "syscall")) || "").strip
        STDERR.puts "  pid #{pid} tid #{File.basename(task)} state #{state} " \
                    "wchan #{wchan.empty? ? "?" : wchan} syscall #{syscall.empty? ? "?" : syscall}"
      end
    end

    private def self.collect_descendants(parent : Int32, acc : Array(Int32)) : Nil
      each_child(parent) do |pid|
        acc << pid
        collect_descendants(pid, acc)
      end
    end

    private def self.kill_tree(parent : Int32) : Nil
      each_child(parent) do |pid|
        kill_tree(pid)
        LibC.kill(pid, LibC::SIGKILL)
      end
    rescue
    end

    private def self.each_child(parent : Int32, &) : Nil
      Dir.glob("/proc/[0-9]*").each do |dir|
        pid = File.basename(dir).to_i
        yield pid if parent_of(pid) == parent
      end
    end

    private def self.parent_of(pid : Int32) : Int32?
      stat = read_file("/proc/#{pid}/stat") || return nil
      rest = stat[(stat.rindex(')') || 0) + 2..]? || return nil
      rest.split(' ')[1]?.try(&.to_i?)
    end

    private def self.cmdline(pid : Int32) : String
      (read_file("/proc/#{pid}/cmdline") || "").gsub('\0', ' ').strip
    end

    private def self.read_file(path : String) : String?
      File.read(path)
    rescue
      nil
    end
  end
end
