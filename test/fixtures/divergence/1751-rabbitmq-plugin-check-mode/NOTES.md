# 1751 - rabbitmq_plugin in check mode fails instead of predicting `changed`

Issue: https://github.com/weirdbricks/krikri/issues/1751

Found by `krikri-playbook-generator` (playbook
`000027-multi-rabbitmq_plugin-happy`, task `Rabbitmq_plugin #27.0`) on fresh
reference hosts in check mode: real `ansible-playbook` printed
`changed: [target]`, krikri printed a fatal

```
Failed to enable plugin wufeut: Error:
{:plugins_not_found, [:wufeut]}
```

`community.rabbitmq.rabbitmq_plugin` declares `supports_check_mode=True` and
sends every `rabbitmq-plugins` call through `_exec()`, which skips the
invocation in check mode - only the `list -E -m` probe is force-executed. The
requested names are still appended to `enabled`/`disabled`, so the task
reports `changed` for a plugin the broker does not even ship. krikri ran the
enable for real, which is why the missing plugin failed the task.

The stub `fakebin/rabbitmq-plugins` models a broker that lists only
`rabbitmq_management` and dies on an unknown plugin name, so the pre-fix
failure and the fixed `changed:` line are both reproducible without RabbitMQ.
The task YAML is the generator's, with `delegate_to` dropped so it runs
against localhost; `environment: PATH` puts the stub first for both engines.
