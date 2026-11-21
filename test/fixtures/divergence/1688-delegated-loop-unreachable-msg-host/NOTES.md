Issue: https://github.com/weirdbricks/krikri/issues/1688

Found while verifying #1663. A LOOPED task delegated to an ssh host whose
transport always fails showed three output divergences from ansible-core
2.21.6 (booking was already right: unreachable=1 failed=0, exit 4):

1. The `[ERROR]` msg named the ORIGIN host
   (`Data could not be sent to remote host "localctl"`) where real names the
   connection host it dialled - the delegate's `ansible_host`
   (`"192.0.2.1"`). krikri recomposed the loop item's msg off the origin
   host instead of the item's delegate host.
2. krikri printed the two-segment chain (`Task failed.` head, then
   `<<< caused by >>>`) for a delegated unreachable whose ORIGIN is a local
   connection; real prints the single plain block - the same shape the
   non-looped report_unreachable path already produces for delegated tasks
   whatever the origin's connection is (#650).
3. (already correct on the fixed tree) the per-item line label
   `failed: [localctl -> target] (item=one)`.

Repro (the case's own playbook.yml/inventory.ini): the ssh wrapper
`always-fail` prints `Connection to 192.0.2.1 closed by remote host.` to
stderr and exits 255; no real host is needed.

Capture notes:

- `env.txt` pins `ANSIBLE_PIPELINING=True`: the harness replaces the
  environment wholesale, and the pipelined "Data could not be sent to
  remote host" lead is both what the issue's transcript shows and what
  puts the delegate's connection host INTO the msg (the plain
  "Failed to connect to the host via ssh" lead carries no host name, so it
  could not pin the msg-host fix).
- The target pins `ansible_python_interpreter`: interpreter discovery is
  its own ssh exec, and its failure renders a DIFFERENT block shape than
  the module exec's (live-verified vs 2.21.6: with discovery unset and
  uncached, real prints the `Task failed.` + `<<< caused by >>>` chain with
  the plain lead; with the interpreter pinned or a cached discovery fact,
  the module exec is the host's first ssh usage and real prints the plain
  block). krikri does not model the discovery exec, so the case pins the
  module-exec scenario, which is the issue's.

Fix: the loop item's unreachable msg composes off the item's delegate host
(its `connection_host` and pipelining layers), and a delegated item's error
block is the plain single segment regardless of the origin's connection;
the chain shape stays for a non-delegated item on a local origin.
