# Compatibility test image: real ansible-core AND a from-source build of
# crystal-ansible, side by side, so compat/run.cr can run the same
# playbook through both and diff the results.
#
# Built FROM the official Crystal image (not a bind-mounted host binary)
# specifically to avoid a glibc version mismatch between the build host and
# the container - crystal-ansible is compiled fresh, inside this image,
# against this image's own glibc.
FROM docker.io/crystallang/crystal:1.20.3

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-venv \
    git \
    cron \
    openssh-client \
    ca-certificates \
    bzip2 \
    xz-utils \
    zip \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Debian/Ubuntu block system-wide `pip install` (PEP 668); a venv sidesteps
# that without needing --break-system-packages.
RUN python3 -m venv /opt/ansible-venv \
    && /opt/ansible-venv/bin/pip install --no-cache-dir ansible-core
ENV PATH="/opt/ansible-venv/bin:${PATH}"

# authorized_key isn't part of ansible-core - it lives in the separate
# ansible.posix collection (crystal-ansible registers it as
# ansible.posix.authorized_key to match). archive/unarchive likewise live
# in community.general, not ansible-core.
RUN ansible-galaxy collection install ansible.posix community.general

WORKDIR /repo
COPY . /repo
RUN shards install && ./build.sh --release

# Playbooks run here; each `docker run --rm` gets a fresh, empty /work from
# the image layer, discarded when the container exits.
WORKDIR /work
