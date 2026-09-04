# Compatibility test image: real ansible-core AND a from-source build of
# krikri-playbook, side by side, so compat/run.cr can run the same
# playbook through both and diff the results.
#
# Built FROM the official Crystal image (not a bind-mounted host binary)
# specifically to avoid a glibc version mismatch between the build host and
# the container - krikri-playbook is compiled fresh, inside this image,
# against this image's own glibc.
FROM docker.io/crystallang/crystal:1.20.3

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-venv \
    git \
    cron \
    openssh-client \
    openssh-server \
    ca-certificates \
    bzip2 \
    xz-utils \
    zip \
    unzip \
    ufw \
    firewalld \
    apache2 \
    sudo \
    # DB servers + clients for the mysql_db/postgresql_db dump/import
    # compat playbooks (35/36): the playbooks start each server inside
    # the container via its init.d script (no systemd needed). Server and
    # client come from the same distro release, so pg_dump/mysqldump never
    # hit a server-vs-client version mismatch. python3-pymysql /
    # python3-psycopg2 are what real Ansible's own community.mysql /
    # community.postgresql modules import on the *target*'s system python.
    mariadb-server \
    mariadb-client \
    postgresql \
    postgresql-client \
    # rabbitmq node for the rabbitmq_plugin/rabbitmq_user compat playbook
    # (44): the playbook starts the node itself as the package's `rabbit`
    # user (no systemd in this image, and rabbitmq refuses to run as root)
    rabbitmq-server \
    python3-pymysql \
    python3-psycopg2 \
    # link-time deps for the native-format plugins (archive's bz2/xz/z,
    # stat/find/file's openssl checksums). xz-utils above only ships the
    # runtime libs; the -dev packages provide the headers + pkg-config
    # files crystal needs to link -- without liblzma-dev, the release
    # build emitted a broken '--llzma' fallback flag and cc failed.
    libbz2-dev \
    liblzma-dev \
    zlib1g-dev \
    libssl-dev \
    libpcre2-dev \
    && rm -rf /var/lib/apt/lists/*

# Debian/Ubuntu block system-wide `pip install` (PEP 668); a venv sidesteps
# that without needing --break-system-packages. --system-site-packages
# lets the venv see the apt-installed python3-psycopg2/python3-pymysql
# above - community.postgresql.postgresql_db imports psycopg2 directly
# (not a subprocess call like mysql_db's mysqldump/mysql shelling), so
# without this the venv's own isolated site-packages can't find it and
# every postgresql_* task fails with "Failed to import the required
# Python library (psycopg2)" regardless of the module's own correctness.
RUN python3 -m venv --system-site-packages /opt/ansible-venv \
    && /opt/ansible-venv/bin/pip install --no-cache-dir ansible-core
ENV PATH="/opt/ansible-venv/bin:${PATH}"

# authorized_key isn't part of ansible-core - it lives in the separate
# ansible.posix collection (krikri-playbook registers it as
# ansible.posix.authorized_key to match). archive/unarchive likewise live
# in community.general, not ansible-core. mysql_db/mysql_user and
# postgresql_db/postgresql_user live in community.mysql /
# community.postgresql.
RUN ansible-galaxy collection install ansible.posix community.general \
    community.mysql community.postgresql community.rabbitmq

WORKDIR /repo
COPY . /repo
# Debug build: the harness compares behavior (exit codes + filesystem
# state), not performance, and a debug build recompiles in a fraction of
# the time - important because any source change invalidates this layer.
# Release vs. debug produces identical plugin output for compat purposes.
RUN shards install && ./build.sh

# item 3 compat coverage (--experimental-batching, 0.9.61): the normal
# harness runs both engines via `docker exec <container> ...` with
# ansible_connection=local (compat/inventory.ini), which never touches
# batching at all - it's an SSH-specific optimization. compat/run.cr's
# compare_batching instead spins up two containers *from this same
# image* and has one reach the other over a real SSH connection, so
# every container built from this image is set up to both host sshd
# (the "target" role) and SSH into a sibling container (the
# "controller" role) using one baked-in keypair.
#
# batching_test_key(.pub) is intentionally committed to this repo, not
# a secret needing rotation - it grants access to nothing except an
# ephemeral, throwaway container built from this exact image, on
# whichever machine builds it; it is never used against any real host
# and this image is never exposed to a real network. Same accepted
# pattern as e.g. Vagrant's well-known default box keypair.
RUN ssh-keygen -A \
    && mkdir -p /run/sshd /root/.ssh \
    && chmod 700 /root/.ssh \
    && cp compat/batching_test_key.pub /root/.ssh/authorized_keys \
    && cp compat/batching_test_key /root/.ssh/id_batching_test \
    && chmod 600 /root/.ssh/authorized_keys /root/.ssh/id_batching_test \
    && echo "PermitRootLogin prohibit-password" >> /etc/ssh/sshd_config \
    && printf 'Host *\n  StrictHostKeyChecking accept-new\n  IdentityFile /root/.ssh/id_batching_test\n' > /root/.ssh/config \
    && chmod 600 /root/.ssh/config

# Playbooks run here; each `docker run --rm` gets a fresh, empty /work from
# the image layer, discarded when the container exits.
WORKDIR /work
