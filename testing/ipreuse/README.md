# IP-reuse test for the item-6a plugin state cache

Perf item 6a records, on the CONTROLLER, which plugin binaries were
verified present on which host, so a later run can skip the
verification round trip. The record is keyed on `user@host:port`.

The dangerous case is therefore **a different machine answering at the
same address**: a cloud provider recycling an IP, or a host rebuilt in
place. The cache says "verified", the binaries are not there, and
without a recovery path the run fails.

Waiting for a real provider to hand back a recycled IP is unreliable -
two full benchmark rounds against Atlantic.net never produced one. This
reproduces it deterministically in seconds using containers, by reusing
a fixed forwarded PORT (the cache key includes it, so this is the same
hazard).

## Run it

    ssh-keygen -q -t ed25519 -N '' -f key
    podman build -t ipreuse-test -f Containerfile .

    # 1. populate the cache against one container
    podman run -d --name host-a -p 2222:22 ipreuse-test
    krikri-playbook -i inv.ini play.yml

    # 2. replace it with a DIFFERENT container at the same address
    podman rm -f host-a
    podman run -d --name host-b -p 2222:22 ipreuse-test

    # 3. this must still succeed - recovery re-uploads
    krikri-playbook -i inv.ini play.yml

`inv.ini` is one line:

    target ansible_host=127.0.0.1 ansible_port=2222 ansible_user=root ansible_ssh_private_key_file=$PWD/key

## Expected

Every run completes cleanly. Verified 2026-08-29 at 0.9.638 across four
consecutive impostor swaps, and separately with a 12-task batching play
(`ok=13 changed=12 failed=0`) - the batch path matters because that is
where the recovery was MISSING on the first attempt at item 6a, and a
non-batching test would not have caught it.
