# No `# syntax=` directive on purpose. It would pull the docker/dockerfile
# frontend from the registry on every build — at a floating `:1` tag, in a
# project whose whole point is that nothing floats — and nothing below uses a
# feature the builtin frontend lacks.

# Telegraf with smartmontools, for collecting disk SMART attributes from
# Kubernetes nodes via the inputs.smartctl or inputs.smart plugin. Both are
# supported: they want the same tool, but look for it in different places, and
# both reach the hardware through a file capability on it rather than sudo.
#
# Every ARG below is supplied by the Rakefile, which is the single source of
# truth for versions. The defaults here only keep a bare `docker build` working
# and are kept in sync with that file by hand.

ARG TELEGRAF_VERSION=1.40.2
ARG BASE_DIGEST=sha256:d3b22c2bd211fd613e4a87b0ca0f74f20b9a7f2b1be3c6e867e98a6d4a51545e

# Pinned by digest, not just by tag. A tag is mutable — upstream rebuilds
# 1.40.2-alpine in place whenever Alpine moves — so the tag alone made the base
# the one input here that could change without a commit. With a digest the tag
# is only documentation: Docker ignores it. That is also the hazard, because
# bumping TELEGRAF_VERSION without the digest would quietly build the old
# release; `rake image:verify` catches it by asserting the Telegraf version.
FROM telegraf:${TELEGRAF_VERSION}-alpine@${BASE_DIGEST}

ARG SMARTMONTOOLS_VERSION=7.5-r0
ARG ZLIB_VERSION=1.3.2-r1

# Exact apk pins, for the same reason the base is pinned. A pin that no longer
# resolves fails the build loudly instead of silently installing whatever
# Alpine serves today; `rake image:versions` reports what to bump to.
#
# smartmontools alone: `nvme-cli` is deliberately not installed. smartctl reads
# NVMe SMART itself, so the only thing nvme-cli added was inputs.smart's
# vendor-specific log pages — and it had to carry cap_sys_admin to do it. See
# README.md, "Capabilities, not sudo or root".
#
# zlib is a security override of a package the base already ships: its
# 1.3.2-r0 has CVE-2026-85091, a heap overflow fixed in -r1. Drop the pin once
# the pinned base itself ships -r1 or later.
RUN set -eux; \
    apk add --no-cache \
        "smartmontools=${SMARTMONTOOLS_VERSION}" \
        "zlib=${ZLIB_VERSION}"

# Alpine installs smartctl under /usr/sbin, which is where inputs.smartctl
# looks by default. inputs.smart defaults to /usr/bin instead (path_smartctl =
# "/usr/bin/smartctl"), so without this symlink that plugin fails to find the
# tool unless every consumer overrides the path. The symlink lets both plugins
# work as documented.
#
# A file capability lives on the inode, so a symlink to a capability-carrying
# binary confers the same privileges — verified, and the reason this needs no
# capabilities of its own.
RUN set -eux; \
    ln -s /usr/sbin/smartctl /usr/bin/smartctl

# Capabilities instead of sudo, so smartctl carries exactly the privileges its
# own ioctls need and Telegraf keeps running as uid 100 with none of them:
#
#   cap_dac_override  opens the device nodes. They are root:disk and closed to
#                     uid 100, and /dev is bind-mounted from the host, so
#                     joining a group here would depend on the host's disk GID
#                     matching this image's. Override rather than read_search
#                     because the hardware-RAID paths (aacraid, megaraid,
#                     cciss, Areca) open their device O_RDWR.
#   cap_sys_rawio     SG_IO and ATA passthrough — SATA and SAS SMART.
#   cap_sys_admin     NVMe Get Log Page, which carries the SMART/health data.
#                     The kernel permits unprivileged NVMe passthrough for only
#                     five Identify variants (nvme_admin_cmd_allowed in
#                     drivers/nvme/host/ioctl.c); the health log is not among
#                     them, and there is no narrower capability for it.
#
# Telegraf gets one of its own, plus the two the upstream entrypoint used to
# set at every container start:
#
#   cap_dac_read_search  lists another process's /proc/<pid>/fd, which is
#                        dr-x------ owned by that process's user. It is what
#                        makes inputs.procstat report num_fds for processes
#                        Telegraf does not own. Counting descriptors only reads
#                        that directory, so cap_sys_ptrace — which governs
#                        resolving the symlinks inside it — is not needed.
#   cap_net_raw,
#   cap_net_bind_service what the upstream entrypoint granted, preserved here
#                        because this image no longer runs that entrypoint.
#
# And ping, which upstream ships setuid root, gets cap_net_raw instead — the one
# privilege it uses. A setuid-root binary was the only path in the image from
# uid 100 to uid 0, and in a privileged pod uid 0 is root on the node.
#
# The assertions matter because every way this breaks is silent. A file
# capability is an xattr, and a build or export that dropped xattrs would leave
# the setcap calls recorded but inert — so one capability is proven to actually
# take effect for uid 100 before the others are trusted.
RUN set -eux; \
    setcap cap_dac_override,cap_sys_rawio,cap_sys_admin+ep /usr/sbin/smartctl; \
    setcap cap_net_raw,cap_net_bind_service,cap_dac_read_search+ep /usr/bin/telegraf; \
    chmod u-s /bin/ping; \
    setcap cap_net_raw+ep /bin/ping; \
    [ "$(getcap /usr/sbin/smartctl)" = "/usr/sbin/smartctl cap_dac_override,cap_sys_rawio,cap_sys_admin=ep" ]; \
    [ "$(getcap /usr/bin/telegraf)" = "/usr/bin/telegraf cap_dac_read_search,cap_net_bind_service,cap_net_raw=ep" ]; \
    [ "$(getcap /bin/ping)" = "/bin/ping cap_net_raw=ep" ]; \
    [ -z "$(find / -xdev -type f -perm /6000)" ]; \
    cp /bin/busybox /tmp/busybox; \
    setcap cap_dac_override+ep /tmp/busybox; \
    printf 'probe\n' > /root/probe; \
    chmod 600 /root/probe; \
    [ "$(su telegraf -s /bin/sh -c '/tmp/busybox cat /root/probe')" = 'probe' ]; \
    rm -f /tmp/busybox /root/probe

# Running either binary cannot be asserted here, only in `rake image:verify`.
# With the file effective bit set, execve fails with EPERM unless the calling
# process can obtain every capability in the file's permitted set, and the build
# sandbox's bounding set carries none of cap_sys_rawio, cap_sys_admin or
# cap_dac_read_search — so even root cannot exec them during a build. The probe
# above uses cap_dac_override alone, which the sandbox does have, which is why
# it can prove the mechanism while these cannot.
#
# The same rule governs deployment, and now binds Telegraf itself: without
# cap_dac_read_search in the container's bounding set the image does not start
# at all. See README.md, "What the consumer has to provide".

# Upstream's /entrypoint.sh is deliberately not used. It exists to start as
# root, setcap the Telegraf binary, and drop to uid 100 with setpriv — all of
# which is either done above at build time or handled by USER below. Running as
# the telegraf user declaratively means the container never needs uid 0, the
# runtime applies supplementalGroups itself rather than the entrypoint merging
# them by hand, and nothing re-runs setcap on every start.
#
# HOME is set because the entrypoint used to export it; /home/telegraf exists
# and belongs to the user. CMD is cleared because the base image's `telegraf`
# would otherwise arrive as a stray argument to the binary now in ENTRYPOINT.
#
# /etc/telegraf goes to root because upstream hands it to the telegraf user,
# which lets the running process rewrite its own configuration. Telegraf only
# ever reads it, and consumers mount their config over it anyway.
RUN chown -R root:root /etc/telegraf

ENV HOME=/home/telegraf
USER telegraf
ENTRYPOINT ["/sbin/tini", "--", "/usr/bin/telegraf"]
CMD []

ARG IMAGE_VERSION=1.40.2-alpine.0
ARG SOURCE_COMMIT=unknown
# Redeclared because an ARG set before FROM is out of scope after it. The
# labels' TELEGRAF_VERSION needs no such line only because the base image
# happens to export it as an ENV.
ARG BASE_DIGEST

LABEL org.opencontainers.image.title="telegraf" \
      org.opencontainers.image.description="Telegraf ${TELEGRAF_VERSION} (Alpine) plus smartmontools, capability-equipped for inputs.smartctl and inputs.smart" \
      org.opencontainers.image.base.name="docker.io/library/telegraf:${TELEGRAF_VERSION}-alpine" \
      org.opencontainers.image.base.digest="${BASE_DIGEST}" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${SOURCE_COMMIT}" \
      org.opencontainers.image.licenses="MIT"
