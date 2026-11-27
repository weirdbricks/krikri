require "./src/krikri/process_spawn_retry"
require "./src/krikri/ssm_pipe_bridge"

exit Krikri::SsmPipeBridge.run(ARGV)
