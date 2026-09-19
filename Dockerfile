# No `# syntax=` directive on purpose. It would pull the docker/dockerfile
# frontend from the registry on every build — at a floating `:1` tag, in a
# project whose whole point is that nothing floats — and nothing below uses a
# feature the builtin frontend lacks.

# Telegraf with smartmontools, for collecting disk SMART attributes from
# Kubernetes nodes via the inputs.smartctl or inputs.smart plugin. Both are
# supported: they want the same two tools, but look for them in different
# places and reach them through the same sudo policy.
#
# Every ARG below is supplied by the Rakefile, which is the single source of
# truth for versions. The defaults here only keep a bare `docker build` working
# and are kept in sync with that file by hand.

ARG TELEGRAF_VERSION=1.40.0

# Pinned to the exact patch tag rather than 1.40-alpine or latest, so the base
# is reproducible for as long as the tag exists.
FROM telegraf:${TELEGRAF_VERSION}-alpine

ARG SMARTMONTOOLS_VERSION=7.5-r0
ARG NVME_CLI_VERSION=2.16-r1
ARG SUDO_VERSION=1.9.17_p2-r0

# Exact apk pins, for the same reason the base tag is pinned. A pin that no
# longer resolves fails the build loudly instead of silently installing
# whatever Alpine serves today; `rake image:versions` reports what to bump to.
RUN set -eux; \
    apk add --no-cache \
        "smartmontools=${SMARTMONTOOLS_VERSION}" \
        "nvme-cli=${NVME_CLI_VERSION}" \
        "sudo=${SUDO_VERSION}"

# Alpine installs both tools under /usr/sbin, which is where inputs.smartctl
# looks by default. inputs.smart defaults to /usr/bin instead (path_smartctl =
# "/usr/bin/smartctl", path_nvme = "/usr/bin/nvme"), so without these symlinks
# that plugin fails to find either tool unless every consumer overrides both
# paths. The symlinks let both plugins work as documented.
#
# sudo matches a command path literally rather than resolving it, so these
# paths need their own entries in the sudoers policy — they are there, and the
# assertions below prove it rather than assuming it.
RUN set -eux; \
    ln -s /usr/sbin/smartctl /usr/bin/smartctl; \
    ln -s /usr/sbin/nvme /usr/bin/nvme

COPY sudoers.d/telegraf /etc/sudoers.d/telegraf

# Build-time assertions, because each of these fails at runtime in a way that
# is tedious to diagnose from a metrics gap:
#
#   1. sudo refuses to read any sudoers file that is group- or world-writable,
#      and ignores it silently rather than erroring.
#   2. visudo -c catches a malformed rule here rather than on a node.
#   3. The four su calls are the ones that matter: they run as the same
#      unprivileged user the entrypoint drops to, and prove the policy actually
#      grants both plugins' paths. A sudoers entry naming a path that does not
#      exist, or that exists only as an unlisted symlink, parses cleanly and
#      still denies every call — which is exactly the mistake the /usr/bin
#      aliases invite.
RUN set -eux; \
    chown root:root /etc/sudoers.d/telegraf; \
    chmod 0440 /etc/sudoers.d/telegraf; \
    visudo -c -f /etc/sudoers.d/telegraf; \
    su telegraf -s /bin/sh -c 'sudo -n /usr/sbin/smartctl --version' > /dev/null; \
    su telegraf -s /bin/sh -c 'sudo -n /usr/sbin/nvme version' > /dev/null; \
    su telegraf -s /bin/sh -c 'sudo -n /usr/bin/smartctl --version' > /dev/null; \
    su telegraf -s /bin/sh -c 'sudo -n /usr/bin/nvme version' > /dev/null

# ENTRYPOINT, CMD, EXPOSE and the telegraf user are inherited from the base
# image and deliberately left alone: the upstream entrypoint's privilege drop
# is what this image is built around rather than against. Overriding it is what
# running Telegraf as root would require — see README.md, "Root or sudo".

ARG IMAGE_VERSION=1.40.0-r.0+alpine
ARG SOURCE_COMMIT=unknown

LABEL org.opencontainers.image.title="telegraf" \
      org.opencontainers.image.description="Telegraf ${TELEGRAF_VERSION} (Alpine) plus smartmontools, nvme-cli and a scoped sudo policy for inputs.smartctl and inputs.smart" \
      org.opencontainers.image.base.name="docker.io/library/telegraf:${TELEGRAF_VERSION}-alpine" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${SOURCE_COMMIT}" \
      org.opencontainers.image.licenses="MIT"
