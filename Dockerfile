# No `# syntax=` directive on purpose. It would pull the docker/dockerfile
# frontend from the registry on every build — at a floating `:1` tag, in a
# project whose whole point is that nothing floats — and nothing below uses a
# feature the builtin frontend lacks.

# Telegraf for collecting disk SMART attributes, LVM usage and ZFS pool health
# from Kubernetes nodes, via inputs.smartctl, inputs.smart, inputs.lvm and an
# inputs.exec of `zpool list`. The image ships none of the tools those call:
# node-tool runs the node's own smartctl, pvs, vgs, lvs and zpool in the node's
# mount namespace, each with only the options Telegraf passes and only the
# capabilities its reporting needs.
#
# Every ARG below is supplied by the Rakefile, which is the single source of
# truth for versions. The defaults here only keep a bare `docker build` working
# and are kept in sync with that file by hand.
#
# Two kinds of pin. Our version pins the tooling base: the Alpine image, by
# digest, that node-tool is built on and the test host runs. A build pins the
# Telegraf release and the digest of its base — the only inputs that differ
# between the builds of one version of ours. Packages are not pinned: each
# stage takes what its Alpine release serves.

ARG TELEGRAF_VERSION=1.40.0
ARG BASE_DIGEST=sha256:de158bd5b050cbb763fdc921bd01c8faf85408317176ccbcca2ca514debbaa1f
ARG TOOLING_BASE=alpine:3.23.7
ARG TOOLING_DIGEST=sha256:ff7f0c727dd796aa36787bfcd9a64bf35a6ce72a73451b3359fde849b6703d63

# Builds node-tool; see node-tool/src/main.rs. On the tooling base, not the
# Telegraf base: Telegraf releases sit on different Alpine releases, while the
# tooling base is the same for every build of one version of ours, and with it
# its Alpine release's Rust — a stable branch keeps its Rust version and only
# takes patch rebuilds. Statically linked, so the binary runs on any base and
# nothing from this stage but the one file reaches the image. --locked and
# --offline: the crate has no dependencies, and the build must not quietly
# acquire one.
FROM ${TOOLING_BASE}@${TOOLING_DIGEST} AS node-tool

RUN set -eux; \
    apk add --no-cache rust cargo
COPY node-tool /build
WORKDIR /build
RUN set -eux; \
    RUSTFLAGS="-C target-feature=+crt-static" cargo build --release --locked --offline; \
    [ -z "$(scanelf -qn target/release/node-tool)" ]

# A stand-in node for `rake image:verify`, never published: the same pinned
# base with the node-side tools the image deliberately lacks. Verification
# starts it, gives it a throwaway volume group, and runs the node-tool checks
# against it as a pod runs against a node. Before the image stage, because a
# plain `docker build` builds the last stage, and that has to stay the image.
#
# smartmontools alone, no nvme-cli: smartctl reads NVMe SMART itself, and
# nvme-cli only ever served inputs.smart's vendor-specific log pages. zfs for
# its zpool; without the kernel module, which no container can load, it only
# proves that node-tool reaches it, not a pool.
#
# Unpinned: whatever the tooling base's Alpine release serves. These stand in
# for a node's tools, whose versions this image does not control either, and
# none of them reaches the published image.
FROM ${TOOLING_BASE}@${TOOLING_DIGEST} AS test-host

RUN set -eux; \
    apk add --no-cache smartmontools lvm2 zfs

# Pinned by digest, not just by tag. A tag is mutable — upstream rebuilds
# 1.40.2-alpine in place whenever Alpine moves — so the tag alone made the base
# the one input here that could change without a commit. With a digest the tag
# is only documentation: Docker ignores it. That is also the hazard, because
# bumping TELEGRAF_VERSION without the digest would quietly build the old
# release; `rake image:verify` catches it by asserting the Telegraf version.
FROM telegraf:${TELEGRAF_VERSION}-alpine@${BASE_DIGEST} AS image

# Nothing is installed: smartctl, the LVM tools and zpool are the node's, run
# through node-tool, so the node's versions and configuration apply. Nor are
# the base's own packages upgraded — a build is pinned to its base digest and
# never rebuilt, so what the base ships is what the build carries.

# The links are where the plugins look, and all lead to node-tool, which takes
# the tool from the name it was called by: /usr/sbin/smartctl for
# inputs.smartctl, /usr/bin/smartctl for inputs.smart, which defaults there
# (path_smartctl = "/usr/bin/smartctl"), /usr/sbin/{pvs,vgs,lvs} for
# inputs.lvm, and /usr/sbin/zpool for the pool-health exec in
# examples/zfs.conf. A file capability lives on the inode, so a link confers the
# wrapper's privileges without any of its own.
COPY --from=node-tool /build/target/release/node-tool /usr/libexec/node-tool
RUN set -eux; \
    for tool in smartctl pvs vgs lvs zpool; do ln -s /usr/libexec/node-tool "/usr/sbin/$tool"; done; \
    ln -s /usr/libexec/node-tool /usr/bin/smartctl

# Capabilities instead of sudo or root, each on the binary whose own work needs
# it, so Telegraf keeps running as uid 100.
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
# node-tool holds the union of what the node's tools need, and hands each tool
# only its own, as ambient capabilities. smartctl gets three:
#
#   cap_dac_override  opens the device nodes. They are root:disk and closed to
#                     uid 100. Override rather than read_search because the
#                     hardware-RAID paths (aacraid, megaraid, cciss, Areca)
#                     open their device O_RDWR.
#   cap_sys_rawio     SG_IO and ATA passthrough — SATA and SAS SMART.
#   cap_sys_admin     NVMe Get Log Page, which carries the SMART/health data.
#                     The kernel permits unprivileged NVMe passthrough for only
#                     five Identify variants (nvme_admin_cmd_allowed in
#                     drivers/nvme/host/ioctl.c); the health log is not among
#                     them, and there is no narrower capability for it.
#
# pvs, vgs and lvs get three, each found by removing it:
#
#   cap_dac_override  opens /dev/mapper/control, which a host keeps root-only
#                     and 0600, and which LVM opens read-write even to report —
#                     switching activation off in lvm.conf does not avoid it.
#                     Read-only cap_dac_read_search is therefore not enough
#                     (measured: "/dev/mapper/control: open failed"). It also
#                     covers the root:disk device nodes and LVM's root-owned
#                     lock directory, /run/lock/lvm.
#   cap_fowner        LVM opens devices with O_NOATIME, which the kernel
#                     permits only to the file's owner or with this; without it
#                     every device fails with "has no path names".
#   cap_sys_admin     the device-mapper ioctls that report whether a logical
#                     volume is active; without it the state reads unknown
#                     (-wi-XX).
#
# zpool gets cap_dac_override alone: libzfs opens /dev/zfs read-write even to
# list pools, and a node can keep it root-only 0600 (measured on a CI runner
# with the ZFS module loaded: "the ZFS utilities must be run as root").
#
# And two only for reaching the node's tools at all:
#
#   cap_sys_ptrace    opens /hostfs/proc/1/ns/mnt, the node's mount namespace
#                     in the node's /proc, which the consumer mounts at
#                     /hostfs/proc. The kernel guards it with a ptrace check;
#                     Telegraf lacks this capability, so it cannot open it.
#   cap_sys_chroot    setns into that namespace, together with cap_sys_admin.
#                     Entering it rather than chrooting also brings the node's
#                     mount table, which LVM reads to find sysfs.
#
# The tools are far more than reporters: lvm is the whole LVM suite, and with
# its capabilities uid 100 could create, remove and wipe the node's volumes
# (lvcreate, lvremove, pvremove — measured); smartctl can start self-tests and
# change device settings; zpool can destroy pools. node-tool runs only
# smartctl, pvs, vgs, lvs and `zpool list`, with only the options Telegraf
# passes.
#
# Permitted only (=p), not effective. node-tool makes the entry capabilities
# effective for opening the namespace and the setns call and then removes them
# from every set; a tool's own take effect as ambient capabilities from its
# exec on, with an environment node-tool sets. Without the effective bit the
# kernel also does not refuse the exec where a capability is missing from the
# bounding set — node-tool names the failing step instead.
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
    setcap cap_net_raw,cap_net_bind_service,cap_dac_read_search+ep /usr/bin/telegraf; \
    setcap cap_dac_override,cap_fowner,cap_sys_rawio,cap_sys_admin,cap_sys_chroot,cap_sys_ptrace+p /usr/libexec/node-tool; \
    chmod u-s /bin/ping; \
    setcap cap_net_raw+ep /bin/ping; \
    [ "$(getcap /usr/bin/telegraf)" = "/usr/bin/telegraf cap_dac_read_search,cap_net_bind_service,cap_net_raw=ep" ]; \
    [ "$(getcap /usr/libexec/node-tool)" = "/usr/libexec/node-tool cap_dac_override,cap_fowner,cap_sys_rawio,cap_sys_chroot,cap_sys_ptrace,cap_sys_admin=p" ]; \
    [ "$(getcap /bin/ping)" = "/bin/ping cap_net_raw=ep" ]; \
    [ -z "$(find / -xdev -type f -perm /6000)" ]; \
    cp /bin/busybox /tmp/busybox; \
    setcap cap_dac_override+ep /tmp/busybox; \
    printf 'probe\n' > /root/probe; \
    chmod 600 /root/probe; \
    [ "$(su telegraf -s /bin/sh -c '/tmp/busybox cat /root/probe')" = 'probe' ]; \
    rm -f /tmp/busybox /root/probe

# Telegraf cannot be run here, only in `rake image:verify`. With the file
# effective bit set, execve fails with EPERM unless the calling process can
# obtain every capability in the file's permitted set, and the build sandbox's
# bounding set lacks cap_dac_read_search — so even root cannot exec it during
# a build. The probe above uses cap_dac_override alone, which the sandbox does
# have, which is why it can prove the mechanism while Telegraf cannot.
#
# The same rule governs deployment: without cap_dac_read_search in the
# container's bounding set the image does not start at all. See README.md,
# "What the consumer has to provide".

# Upstream's /entrypoint.sh is deliberately not used. It exists to start as
# root, setcap the Telegraf binary, and drop to uid 100 with setpriv — all of
# which is either done above at build time or handled by USER below. Running as
# the telegraf user declaratively means the container never needs uid 0, the
# runtime applies supplementalGroups itself rather than the entrypoint merging
# them by hand, and nothing re-runs setcap on every start.
#
# USER names the telegraf user by its uid, 100, because the kubelet can only
# enforce runAsNonRoot for a numeric user: with a name it refuses to start the
# container, as it cannot tell the name is not root. The group still comes from
# /etc/passwd.
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
USER 100
ENTRYPOINT ["/sbin/tini", "--", "/usr/bin/telegraf"]
CMD []

ARG IMAGE_VERSION=1.40.0+image.1.0.1-dev
ARG SOURCE_COMMIT=unknown
# Redeclared because an ARG set before FROM is out of scope after it. The
# labels' TELEGRAF_VERSION needs no such line only because the base image
# happens to export it as an ENV.
ARG BASE_DIGEST

LABEL org.opencontainers.image.title="telegraf" \
      org.opencontainers.image.description="Telegraf ${TELEGRAF_VERSION} (Alpine) with a capability-equipped wrapper for the node's smartctl, LVM and zpool tools, for SMART, LVM and ZFS pool-health metrics" \
      org.opencontainers.image.base.name="docker.io/library/telegraf:${TELEGRAF_VERSION}-alpine" \
      org.opencontainers.image.base.digest="${BASE_DIGEST}" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${SOURCE_COMMIT}" \
      org.opencontainers.image.licenses="MIT"
