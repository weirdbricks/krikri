require "../minitest_helper"

# OutputBanner#columns calls ioctl(TIOCGWINSZ) with the address of a stack
# Winsize as the third argument. That address (~0x7ffd...) does not fit in a
# 32-bit int, and a fun declaration typed `arg : Int` made the libfun call
# raise OverflowError at runtime - but only when STDOUT is a tty, so every
# ordinary pipe/file test missed it and every tty run crashed on the first
# PLAY banner. This drives the real binary under a pseudo-TTY (util-linux
# `script -qec`, which hands its child a pty on stdin/stdout/stderr) and
# requires a clean exit with the banner intact; there is no in-suite pty
# infrastructure, so the external helper is the pty here.
private BINARY = File.expand_path("../../bin/krikri-playbook", __DIR__)

describe "playbook run under a pseudo-tty stdout" do
  it "prints the PLAY banner and exits 0 when stdout is a tty (ioctl arg-width regression)" do
    playbook = PluginSpecHelper.tmp_path("tty-banner.yml")
    File.write(playbook, <<-YAML)
      ---
      - name: tty banner smoke
        hosts: all
        gather_facts: false
        tasks:
          - name: say something
            ansible.builtin.debug:
              msg: tty banner smoke
      YAML

    output = IO::Memory.new
    status = Process.run(
      "script",
      ["-qec", "#{BINARY} -i localhost, -c local #{playbook}", "/dev/null"],
      output: output,
      error: output,
    )

    status.exit_code.must_equal(0)
    text = output.to_s
    text.must_include("PLAY [tty banner smoke]")
    text.must_include("TASK [say something]")
    text.wont_include("Arithmetic overflow")
  end

  it "fills the terminal width in PLAY/TASK banners under a fixed-size pty (macOS arm64 ioctl ABI regression)" do
    playbook = PluginSpecHelper.tmp_path("tty-banner-width.yml")
    File.write(playbook, <<-YAML)
      ---
      - name: tty banner width
        hosts: all
        gather_facts: false
        tasks:
          - name: hello
            ansible.builtin.debug:
              msg: hi
      YAML

    # `stty cols` pins the pty width the way ansible is probed: the
    # banner must fill it exactly (line length == columns), like
    # ansible's Display.banner. On macOS arm64 the winsize ioctl used to
    # pass its struct pointer in a register while the variadic libc
    # ioctl reads it from the stack, so the width came back as random
    # uninitialised memory and the banner was a different, too-long
    # length every run (#1065).
    output = IO::Memory.new
    status = Process.run(
      "script",
      ["-qec", "stty cols 120 rows 50; #{BINARY} -i localhost, -c local #{playbook}", "/dev/null"],
      output: output,
      error: output,
    )

    status.exit_code.must_equal(0)
    lines = output.to_s.gsub("\r", "").lines
    play = lines.find { |line| line.starts_with?("PLAY [tty banner width]") }
    task = lines.find { |line| line.starts_with?("TASK [hello]") }
    play.wont_be_nil
    task.wont_be_nil
    play.not_nil!.size.must_equal(120)
    task.not_nil!.size.must_equal(120)
  end
end
