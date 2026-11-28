# 1961 - mysql_* plugins ignored connect_timeout: a blackholed connect hung

- Issue: https://github.com/weirdbricks/krikri/issues/1961
- Side note from #1960.

## What diverged

Every mysql_* plugin parsed `connect_timeout` (ansible.mysql's argument spec
declares it, `default=30`) but never used it: the connection went through
crystal-mysql's bare `TCPSocket.new`, which has no connect timeout. Against a
host whose SYN is silently dropped (192.0.2.1, RFC 5737 TEST-NET-1), krikri
hung for the OS's own ~2-minute connect timeout and then reported an empty
"Exception message:" tail.

Real ansible-core 2.21.6 (ansible.mysql 5.2.0, PyMySQL 2.2.8) fails the task
at the connect_timeout itself:

```
unable to connect to database, check login_user and login_password are
correct or <HOME>/.my.cnf has the credentials. Exception message:
(2003, "Can't connect to MySQL server on '192.0.2.1' (timed out)")
```

PyMySQL passes connect_timeout only to `socket.create_connection` - the TCP
connect - and then resets the socket timeout to `read_timeout` (None by
default) for everything after. That means the issue's other premise does NOT
hold on this stack: a silent peer (accepts, never sends the server greeting)
blocks real's module process forever too, in a bare blocking `recvfrom`
(live-verified with strace). Both engines hang, so there is no divergence to
fix on the handshake-read path, and this case pins the bounded connect
instead.

## The fix

- crystal-mysql fork (`crystal-ansible-0.9.343`): a `connect_timeout=N`
  URI query param bounds the TCP connect; expiry raises
  `DB::ConnectionRefused` with the `IO::TimeoutError` as its cause, so the
  plugin layer can tell a timeout from any other refused connection.
- `MysqlConnection.build_uri` threads the task's `connect_timeout` into the
  URI for every mysql_* plugin, defaulting to the argument spec's 30.
- The connection-failure wrappers word the PyMySQL timeout tail
  `(2003, "Can't connect to MySQL server on '<host>' (timed out)")` without
  re-probing the dead host. mysql_info's variant (which names the connector)
  gets the same tail.

## What this case pins

The issue's repro adapted to the connect-timeout path, all three
generic-wrapper modules in one transcript with `ignore_errors: true`, at
`connect_timeout: 1` so the three blackholed connects cost the replay ~3s.

The fourth task pins the range check: PyMySQL's own `__init__` rejects a
`connect_timeout` outside `(0, 31536000]` with ValueError before any socket
exists (live-verified vs ansible-core 2.21.6 - `connect_timeout: 0` fails in
milliseconds with `connect_timeout should be >0 and <=31536000` as the
wrapper's tail), where the shard's parse would silently drop the value and
leave the OS's own ~2-minute connect timeout in charge.

`mysql_info` is deliberately NOT in the case: its wrapper names the connector
version the TARGET's Python has installed ("using pymysql 1.2.3"), so a
recording would pin this box's PyMySQL build and fail on any host with a
different one (CI installs `python3-pymysql`). Its wording - including the
timed-out and range-failure tails - is pinned by the plugin specs instead
(`mysql_connection_test.cr`; same reasoning as 1962).

The blackholed address is load-bearing: a host where 192.0.2.1:3306 answers
fast (refused or open) would word the tail with its own errno and fail the
replay. The unix-socket connect timeout PyMySQL also sets
(`sock.settimeout(connect_timeout)` around the AF_UNIX connect) is NOT
implemented: a unix-socket connect that outlives connect_timeout requires a
listener with an exhausted accept backlog, which no reproducible corpus case
can pin.

`env.txt` carries the same two overrides as 1962 (PYTHONPATH for the driver
gate, ANSIBLE_DEPRECATION_WARNINGS=False for the _text shim and redirect
deprecations).

`expected.out` is real ansible-core 2.21.6's transcript, captured with
`bin/krikri-capture-case` (never from krikri).
