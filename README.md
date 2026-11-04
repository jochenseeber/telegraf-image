# Telegraf for SMART, LVM and ZFS metrics

A Telegraf container image for collecting disk SMART attributes, LVM volume
usage and ZFS pool health from Kubernetes nodes. Both SMART plugins work out of
the box — [`inputs.smartctl`][smartctl-plugin] and the older
[`inputs.smart`][smart-plugin] — and so do [`inputs.lvm`][lvm-plugin] and
[`inputs.zfs`][zfs-plugin], with pool health from `zpool list`. They run the
**node's own** `smartctl`, `pvs`, `vgs`, `lvs` and `zpool`, through a small
wrapper: the image ships none of those tools, so there is no version skew
between image and node.

Published as **`jochen/telegraf:1.40.0_image.1.1.0-dev`**.

Each image is a **build** of two versions: this project's, `1.0.0`, and the
Telegraf release it is built on, `1.40.2` — named `1.40.2+image.1.0.0`:
Telegraf's version first, since that is what consumers choose by, and ours as
semver build metadata, labelled `image.` so the name says which version is
which. Every version of ours is built with every tracked Telegraf release:

|                                    | Format                               | Example                              |
| ---------------------------------- | ------------------------------------ | ------------------------------------ |
| version of ours                    | git tag `v<ours>`                    | `v1.0.0`                             |
| build                              | `<telegraf>+image.<ours>`            | `1.40.2+image.1.0.0`                 |
| image tag                          | `+` as `_`, since Docker rejects `+` | `jochen/telegraf:1.40.2_image.1.0.0` |
| `org.opencontainers.image.version` | the build's name                     | `1.40.2+image.1.0.0`                 |

`_` cannot occur in either version, so the tag is unambiguous, but read a
build's version from its label rather than by parsing the tag.

[smartctl-plugin]: https://github.com/influxdata/telegraf/tree/master/plugins/inputs/smartctl
[smart-plugin]: https://github.com/influxdata/telegraf/tree/master/plugins/inputs/smart
[lvm-plugin]: https://github.com/influxdata/telegraf/tree/master/plugins/inputs/lvm
[zfs-plugin]: https://github.com/influxdata/telegraf/tree/master/plugins/inputs/zfs

## Why this image exists

The official Telegraf images cannot read SMART data. Both 1.40 Dockerfiles, the
Debian and the Alpine one, install `lm_sensors`, `iputils`, `net-snmp-tools`,
`procps`, `tzdata`, `setpriv`, `libcap` and `tini` — and no `smartmontools`. An
upstream request to add the package was opened in December 2021 and closed
without it landing. Installing it would not be enough anyway: the tools need
privileges an unprivileged Telegraf must not have.

## What it adds over upstream

Built on `telegraf:1.40.0-alpine`, pinned by digest, unmodified except for:

- **`node-tool`**, a small wrapper that runs the node's own `smartctl`, `pvs`,
  `vgs`, `lvs` and `zpool` in the node's mount namespace, each with only the
  options Telegraf's plugins pass and only the capabilities its reporting
  needs. Written in Rust, statically linked, no dependencies; see
  [`node-tool/src/main.rs`](node-tool/src/main.rs).
- Links where the plugins look, all leading to `node-tool`, which takes the
  tool from the name it was called by: `/usr/sbin/smartctl` for
  `inputs.smartctl`, `/usr/bin/smartctl` for `inputs.smart`, which defaults
  there, `/usr/sbin/{pvs,vgs,lvs}` for `inputs.lvm`, and `/usr/sbin/zpool` for
  pool health.
- **`ping` with `cap_net_raw` instead of setuid root.** It was the only setuid
  file in the image, and so the only path from uid 100 to uid 0 — which, in a
  privileged pod, is root on the node. It works exactly as before.
- **`/etc/telegraf` owned by root.** Upstream gives it to the `telegraf` user,
  which lets the running process rewrite its own configuration.

Nothing else of the base image is removed or wrapped.

`nvme-cli` is not used at all. `smartctl` reads NVMe SMART itself, so the only
thing `nvme` added was `inputs.smart`'s vendor-specific log pages. See "Which
plugin".

The exposed ports and the `telegraf` user are inherited from upstream. The
entrypoint and command are replaced — see "Capabilities, not sudo or root".

## Which plugin

**`inputs.smartctl`** is the newer one and the better default. It parses
`smartctl`'s JSON output, and it reads NVMe devices through `smartctl` itself —
its documentation is explicit that, "contrary to the smart plugin, this plugin
does not use the `nvme-cli` package". It needs `smartctl` 7.0 or newer on the
node. Configuration: [`examples/smartctl.conf`](examples/smartctl.conf).

**`inputs.smart`** is the older one. It works here, and it emits a different
metric and tag shape, so the two are not drop-in replacements for each other in
existing dashboards — that shape is the only reason left to choose it.
Configuration: [`examples/smart.conf`](examples/smart.conf).

What this image does **not** support is that plugin's `enable_extensions`,
which shells out to `nvme` for vendor-specific NVMe log pages (Intel and
friends). `node-tool` does not run `nvme`, so the option must stay unset. NVMe
SMART itself is unaffected — `smartctl` reads it either way.

Pick `inputs.smartctl` unless something already depends on `inputs.smart`'s
metrics.

## ZFS

**`inputs.zfs`** on Linux reads only `/proc/spl/kstat/zfs`: ARC, prefetch and
per-pool I/O statistics, which every container sees as the node's. It runs no
commands and needs no privileges.

What it does not report on Linux is **pool health and capacity** — only its
FreeBSD variant runs `zpool list`. So [`examples/zfs.conf`](examples/zfs.conf)
adds an `inputs.exec` that runs the node's `zpool list -H -p -o …` through
`node-tool` and parses it into a `zfs_pool` measurement: the pool's name as the
`pool` tag, as `inputs.zfs` names it there, `health` (`ONLINE`, `DEGRADED`, …)
as a tag to alert on, and size, allocation, free space, fragmentation, capacity
and dedup ratio as numbers. Health is a tag rather than a string field because
outputs that take numbers only, such as `outputs.opentelemetry`, drop string
fields without an error.

`zpool` gets only `cap_dac_override`: libzfs opens `/dev/zfs` read-write even
to list pools, and a node can keep it root-only `0600`. That was measured on a
CI runner whose kernel has the ZFS module loaded, where `zpool` without it
fails with "the ZFS utilities must be run as root". No container can create a
pool, so `image:verify` proves that `node-tool` reaches the node's `zpool` —
answering from the kernel module where the Docker host has one — and that the
example parses `zpool`'s output, but not a live pool.

## Capabilities, not sudo or root

Nothing here runs as root. The image declares `USER 100`, the `telegraf` user,
by number; every privilege it needs sits on a binary as a file capability, sized to
what that binary's own work requires.

Upstream's `/entrypoint.sh` is therefore unused. It exists to start as root,
`setcap` the Telegraf binary and drop to uid 100 with `setpriv` — work that is
either done at build time here or handled by `USER`. Replacing it rather than
patching it means no fork of upstream shell code to re-check each release, no
`setcap` running on every container start, and `supplementalGroups` applied by
the runtime instead of merged by hand in shell.

On `telegraf` itself:

- **`cap_dac_read_search`** — lists another process's `/proc/<pid>/fd`, which
  is `dr-x------` owned by that process's user. It is what lets
  `inputs.procstat` report `num_fds` for processes Telegraf does not own.
  Counting descriptors only reads that directory, so `cap_sys_ptrace` — which
  governs resolving the symlinks inside it — is not required.
- **`cap_net_raw`, `cap_net_bind_service`** — what the upstream entrypoint used
  to grant at every start, preserved because that entrypoint no longer runs.

On `ping`, **`cap_net_raw`**, replacing the setuid bit upstream ships.

On `node-tool`, six, each found by taking it away. It hands each tool only its
own, and measured, that is all the node's tools receive. `smartctl` gets:

- **`cap_dac_override`** — opens the device nodes, which are `root:disk` and
  closed to uid 100. Override rather than `cap_dac_read_search` because the
  hardware-RAID paths (`aacraid`, `megaraid`, `cciss`, Areca) open their device
  `O_RDWR`.
- **`cap_sys_rawio`** — `SG_IO` and ATA passthrough, for SATA and SAS SMART.
- **`cap_sys_admin`** — NVMe Get Log Page, which carries the SMART/health data.

`pvs`, `vgs` and `lvs` get:

- **`cap_dac_override`** — LVM opens `/dev/mapper/control` read-write even to
  report, and a host keeps that node root-only and `0600`. Read-only
  `cap_dac_read_search` fails there, and switching device-mapper off in LVM's
  configuration does not avoid the open. It also covers the `root:disk` disk
  nodes and LVM's root-owned lock directory, `/run/lock/lvm`.
- **`cap_fowner`** — LVM opens devices with `O_NOATIME`, which the kernel
  allows only to the file's owner or with this capability. Without it every
  device fails with `has no path names`.
- **`cap_sys_admin`** — the device-mapper ioctls that report whether a logical
  volume is active. Without it the state reads unknown (`-wi-XX`).

`zpool` gets `cap_dac_override` alone, to open `/dev/zfs`; see "ZFS".

And two only for reaching the node's tools at all, which no tool receives:

- **`cap_sys_ptrace`** — opens `/hostfs/proc/1/ns/mnt`, the node's mount
  namespace in the node's `/proc`, which the kernel guards with a ptrace check.
- **`cap_sys_chroot`** — `setns` into it, together with `cap_sys_admin`.

### Why a wrapper, and what it contains

`smartctl` and `lvm` are far more than reporters. `lvm` is the whole LVM suite
in one binary: with its capabilities on `lvm` itself, uid 100 could create,
remove and wipe the node's volumes — measured. `smartctl` can start self-tests
and change device settings, and `zpool` can destroy pools. So the capabilities
sit on `node-tool`, and:

- **It runs only `smartctl`, `pvs`, `vgs`, `lvs` and `zpool list`**, chosen by
  the name it is called through, and only with the options Telegraf's plugins
  pass, matched exactly — LVM accepts abbreviated long options, so a prefix
  match would let `--conf` through as `--config`. Option values are checked
  too: power modes, device types and column names are plain words, and
  `smartctl` devices must be paths under `/dev/`. Anything else — another
  command, `--config`, `-t`, `-s`, `--drivedb`, a path outside `/dev`,
  `zpool destroy` — is refused before the tool runs.
- **It runs the node's tools, in the node's mount namespace.** It reaches that
  namespace through the node's `/proc`, which consumers mount at `/hostfs/proc`
  for Telegraf's process metrics anyway. Telegraf itself cannot open the
  namespace: the kernel's ptrace check needs `cap_sys_ptrace`, which Telegraf
  lacks, and the link then resolves to its own directory (measured, along with
  a `0600` node file staying unreachable). So the node's versions,
  configuration, devices file and filters apply, and the image needs neither
  smartmontools nor LVM.
- **Its capabilities are permitted-only on the file.** The two entry
  capabilities are effective for opening the namespace and the `setns` call,
  then removed from every set. A tool's own take effect as ambient capabilities
  from its `exec` on, and the wrapper replaces the environment first: the
  node's tools carry no file capabilities, so the kernel would not protect them
  from `LD_PRELOAD` and the like.
- **It refuses rather than guesses.** Without the node's `/proc` it says so;
  with the container's own `/proc` mounted in its place it refuses too, rather
  than run itself in a loop; on a node without the tool it says that.
- **It is statically linked and has no dependencies**, so no dynamic loader or
  third-party crate runs as part of it.

The honest accounting: what `node-tool` cannot contain is the tools themselves.
A bug in LVM's metadata parsing or in `smartctl`'s handling of a device's
answers would still run with that tool's capabilities. For SATA and SAS,
`cap_sys_rawio` in place of root is a real reduction. For NVMe it is not much
of one — the kernel permits unprivileged NVMe passthrough for only five
Identify variants (`nvme_admin_cmd_allowed` in `drivers/nvme/host/ioctl.c`),
the health log is not among them, and there is no narrower capability than
`cap_sys_admin` to ask for. So on an NVMe node `smartctl` is close to root, and
saying otherwise would be false comfort. And because these are the node's
tools, LVM locks in the node's `/run/lock/lvm`: correct coordination with LVM
commands on the node, and a write on the node.

The one sharp edge is covered under "What the consumer has to provide": a
capability-bearing binary will not execute at all in a container that lacks
those capabilities.

## What the consumer has to provide

The image cannot grant itself device access. The pod running it needs:

- **`privileged: true`** in the container's security context — see below for
  why, and for the narrower alternative.
- **The node's `/proc` mounted read-only at `/hostfs/proc`**, as for
  `inputs.procstat` with `HOST_PROC`. `node-tool` enters the node through it:

  ```yaml
  volumes:
    - name: proc
      hostPath:
        path: /proc
        type: Directory
  # in the container:
  volumeMounts:
    - name: proc
      mountPath: /hostfs/proc
      readOnly: true
  ```

  No `/dev` mount is needed: the node's tools run in the node's mount namespace
  and use the node's `/dev` — measured, with the pod's own device-mapper and
  loop nodes hidden. Without the `/proc` mount, `node-tool` refuses with
  `mount the node's /proc at /hostfs/proc`. Verified with Docker, which mounts
  volumes with the same runtime; not yet under Kubernetes.
- **The tools on the node**: smartmontools 7.0 or newer for the SMART plugins,
  LVM for `inputs.lvm`, the ZFS tools for pool health. On a node without one,
  `node-tool` says `the node has no smartctl` (or `pvs`, `vgs`, `lvs`,
  `zpool`).
- **`use_sudo = false`** in whichever plugin is configured — the default. There
  is no `sudo` in this image; setting it true looks for a binary that is not
  installed and fails every read.

No `runAsUser` is needed. The image declares `USER 100`, the `telegraf` user,
and starts as it directly, so unlike earlier revisions it never needs to begin
as root. The user is declared by number because that is what lets the kubelet
check it: with a name it refuses `runAsNonRoot` ("image has non-numeric user …
cannot verify user is non-root"). So `runAsNonRoot: true` is accurate and safe
to set, and so is
**`readOnlyRootFilesystem: true`** — Telegraf writes nothing to the image, and
`image:verify` runs it with a read-only root to keep that true. What the node's
tools write, LVM's lock files, is written on the node.

### The capability rule, and why it fails loudly

Telegraf and `ping` carry their capabilities with the effective bit set, and
`execve` refuses such a binary unless the caller can obtain _every_ capability
in its permitted set. Measured: a default container has
`CapBnd: 00000000a80425fb`, and there the image does not start at all:

```text
[FATAL tini (7)] exec /usr/bin/telegraf failed: Operation not permitted
```

So a misconfigured security context fails immediately rather than quietly
dropping a metric. Telegraf needs **three** in the container's bounding set:
`DAC_READ_SEARCH`, `NET_RAW` and `NET_BIND_SERVICE`.

`node-tool` holds its capabilities permitted-only, which the kernel does not
enforce at `exec`, so a missing one fails the plugin rather than the container,
with `node-tool` naming the step that failed. Measured, removing each in turn:

| Missing                                                 | SMART plugins | `inputs.lvm` |
| ------------------------------------------------------- | ------------- | ------------ |
| `DAC_OVERRIDE`, `SYS_ADMIN`, `SYS_CHROOT`, `SYS_PTRACE` | fail          | fail         |
| `SYS_RAWIO`                                             | fail          | work         |
| `FOWNER`                                                | work          | fail         |

So SMART needs `DAC_OVERRIDE`, `SYS_RAWIO`, `SYS_ADMIN`, `SYS_CHROOT` and
`SYS_PTRACE`; LVM swaps `SYS_RAWIO` for `FOWNER`.

**`allowPrivilegeEscalation: false` disables all of it.** It sets
`no_new_privs`, under which the kernel does not grant file capabilities at
`exec`. Measured: `node-tool` then refuses every call with
`capset failed: Operation not permitted` — an error in Telegraf's log on every
collection. Kubernetes refuses that flag alongside `privileged: true`, but it
is the usual default in the narrower configuration below, so it has to be left
off there deliberately.

### Why `privileged`, and what is narrower

`privileged: true` is not something the image needs. It is what Kubernetes
needs to let a container open the host's disk nodes at all. The node's tools
find those nodes in the node's `/dev`, but they still run in the pod's cgroup,
and its device controller refuses to open them. Measured with Docker, with all
capabilities needed and no `privileged`: a disk node visible to the container
fails with `Operation not permitted`, while the same node passed as a device
opens and reads.

So the narrower configuration needs the disks handed to the pod as devices,
which in Kubernetes means a device plugin that advertises the disk nodes. Where
one is available, the container can run with:

```yaml
securityContext:
  runAsNonRoot: true
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: true # required; see above
  seccompProfile:
    type: RuntimeDefault
  capabilities:
    drop: [ALL]
    add: [
      DAC_READ_SEARCH,
      NET_RAW,
      NET_BIND_SERVICE, # Telegraf
      DAC_OVERRIDE,
      SYS_ADMIN,
      SYS_CHROOT,
      SYS_PTRACE, # node-tool
      SYS_RAWIO, # SMART
      FOWNER,
    ] # LVM
```

What that buys, compared with `privileged`: a bounding set of 9 capabilities
instead of all 41 — no `SYS_MODULE`, `SYS_BOOT` or `NET_ADMIN` — and seccomp
left on rather than switched off. This configuration was verified with Docker;
the device plugin side was not.

Ready-to-adapt snippets are in [`examples/`](examples): `smartctl.conf`,
`smart.conf`, `lvm.conf` and `zfs.conf`.

## Building

Requires Docker with buildx, and — to build more than one platform locally —
Docker's containerd image store.

```bash
rake image:config    # show what would be built and published
rake image:build     # multi-platform builds of the image and its test host
rake image:verify    # run the checks against each platform in it
rake image:push      # build, verify, then push exactly what was verified
```

`rake test` is `image:build` plus `image:verify`.

They build the Telegraf release pinned in the `Rakefile`. To build, verify or
push the image on another one by hand, give it as the task's argument; its base
digest is looked up on Docker Hub, as the release workflow does. `test` and
`image:push` hand it on to each task they run. `IMAGE_PLATFORMS` narrows the
platforms:

```bash
rake 'test[1.40.3]'
rake 'image:config[1.40.3]'
IMAGE_PLATFORMS=linux/arm64 rake 'test[1.40.3]'
```

The quotes keep the shell from expanding the brackets.

`IMAGE_BUILD_CACHE=<directory>` keeps every build layer there between runs and
reuses them. CI sets it, keyed by week, so the Rust toolchain is not rebuilt
under emulation on every push. It needs a buildx builder that exports caches,
such as a `docker-container` one or Docker's containerd image store. Releases
never set it.

The release must exist as `telegraf:<version>-alpine` and be at or above
`TELEGRAF_FLOOR`.

`image:build` produces a single multi-platform image under the tag it will be
published as, rather than a set of per-architecture tags — so what gets
verified is the artifact itself, not something that resembles it. It also
builds the test host described below, which is never published. `image:verify`
then reaches each architecture out of that one manifest list with
`docker run --platform`.

`image:verify` runs checks against each platform: the Telegraf version, that
smartmontools, LVM, ZFS and `nvme-cli` are absent, that every privileged binary
carries the expected capabilities and no file is setuid or setgid, that every
plugin's default paths and `ping` run, that `node-tool` is static, runs the
node's `smartctl`, LVM and `zpool`, and refuses commands, options, paths and
setups it should not run with, that the configuration is not writable by uid
100, that a capability actually takes effect for uid 100 rather than merely
being recorded, that the image runs as the `telegraf` user and its entrypoint
reaches the binary, that Telegraf loads each shipped example config and that
`zfs.conf` parses `zpool list` output, and that it and LVM work on a read-only
root filesystem. The base image's digest is asserted through the
`org.opencontainers.image.base.digest` label.

The `node-tool` checks need a node with smartmontools, LVM and ZFS, which the
image does not have. `image:build` also builds a **test host**,
`local/telegraf-test-host` — the tooling base with Alpine's `smartmontools`,
`lvm2` and `zfs`, never published. For each platform, `image:verify` starts it
with a throwaway volume group on a loop device, its disk node at
`root:disk 0660` and `/dev/mapper/control` at `root` `0600`, as a real node has
them. Docker Desktop hands containers world-writable ones, and against those a
capability set too weak for any real node passes — which is exactly how an
earlier revision passed locally and failed in CI.

Those checks then run the way a pod runs on a node: as `telegraf`, in the test
host's process namespace, with a `/proc` of that namespace mounted at
`/hostfs/proc`, so process 1 in it is the test host's init. One goes end to
end, with `inputs.lvm` reading the volume group as uid 100 through
`examples/lvm.conf`. Stopping the test host removes the volume group and the
loop device.

### Versions are pinned, on purpose

Two kinds of pin, owned by two kinds of version:

- **A version of ours pins the tooling base**: `tooling_base`, an Alpine image
  by digest that `node-tool` is built on and the test host runs. Its packages —
  the Rust toolchain, and the test host's smartmontools, LVM and ZFS — are not
  pinned: each stage takes what that Alpine release serves. A stable Alpine
  branch keeps its versions and only takes patch rebuilds, and the test host's
  tools stand in for a node's, whose versions this image does not control
  either.
- **A build pins its Telegraf release and that release's base image**, by
  digest. The tag (`1.40.2-alpine`, never `1.40-alpine` or `latest`) stays in
  the `FROM` line as documentation only: a tag is mutable, and upstream
  rebuilds it in place whenever Alpine moves.

The image itself installs nothing on top of the base, so there are no other
pins. The flip side: a build carries whatever its base ships, and a build is
never rebuilt — a security fix in the base arrives with the next Telegraf
release, or with the next version of ours built against the then-current base.

The CI runners are pinned too (`ubuntu-24.04`, not `ubuntu-latest`), so the
toolchain a build runs against does not change underneath it. That image ships
Docker 28, which has no `--platform` on `docker image inspect` — the Rakefile
falls back for exactly that case, and pinning here is what keeps the fallback
exercised on every run rather than quietly rotting.

## Building every Telegraf release

New Telegraf releases are built automatically, with every version of ours, and
nothing is written to git for them: a build exists only as its image.

**`.github/workflows/release.yml`** runs on a version tag of ours, `vX.Y.Z`. It
goes through every upstream `X.Y.Z-alpine` tag at or above the floor in the
tagged `Rakefile` (`TELEGRAF_FLOOR`, `1.40.0`), oldest first, and for each one
whose build is not yet on Docker Hub, looks up the current digest of its base,
then builds, verifies and pushes `jochen/telegraf:<telegraf>_image.<ours>`. The
Telegraf release and its digest reach the build as arguments; the tag's files
are not changed.

**`.github/workflows/mirror.yml`** runs daily on `main` and only dispatches the
release workflow on every version tag of ours, oldest first, each waited for.
On a day without a new Telegraf release, every build is already on Docker Hub
and nothing is built.

A build already on Docker Hub is done: upstream rebuilding its base in place
changes nothing. Release candidates are not built, and bases older than the
floor predate what the Dockerfile relies on. Within one version of ours, the
first failing build stops the run, so no build lands while an older one is
broken, and the next run starts over from there. A failure means a Telegraf
release this version of ours cannot handle; the fix is a new version of ours.

```bash
rake builds:plan                   # this checkout's builds, and which are published
DRY_RUN=true rake builds:publish   # build and verify what would be published
rake mirror:plan                   # the version tags the mirror runs releases on
```

## Releasing a version of ours

A change to the image — the Dockerfile, `node-tool`, the tooling base — is a
new version of ours. Everything version-shaped lives in the `IMAGE` literal at
the bottom of the [`Rakefile`](Rakefile); the Dockerfile's `ARG` defaults
mirror it so a bare `docker build` works, and have to be updated alongside.

Between releases, `own_version` is a development version, `X.Y.Z-dev`: `main`
carries the next minor release, `X.Y.0-dev`, and each release branch `X.Y.x`
its next patch, `X.Y.Z-dev`. Only a release commit carries a plain `X.Y.Z`, and
only those are tagged — so only those are built and published.

Changes land on `main`. If the tooling base should move with them, refresh its
digest first:

```bash
rake image:versions
```

It prints the current digests of the tooling base and of the Telegraf base CI
tests with, next to the pinned ones; copy them into `tooling_digest` and
`base_digest`, and into the Dockerfile's `ARG` defaults. A new Alpine release
for the tooling base means changing `tooling_base` too.

To release, run `rake release` on a clean checkout:

| Run on  | At          | It does                                                                                                         |
| ------- | ----------- | --------------------------------------------------------------------------------------------------------------- |
| `main`  | `1.0.0-dev` | branches `1.0.x`; there commits `1.0.0`, tags `v1.0.0`, commits `1.0.1-dev`; then commits `1.1.0-dev` on `main` |
| `1.0.x` | `1.0.1-dev` | commits `1.0.1`, tags `v1.0.1`, commits `1.0.2-dev` — a patch release; `main` is left alone                     |

Each version change rewrites `own_version`, the Dockerfile's `IMAGE_VERSION`
and the README's published tag together. A major release is the same from
`main`, after setting `own_version` to `X.0.0-dev` there by hand.

It refuses a dirty tree, any other branch, a version that is not `-dev`, and a
branch or tag that already exists — all before changing anything — and it never
pushes. It prints the push instead:

```bash
git push --atomic origin main 1.0.x v1.0.0
```

Pushing the tag starts the release workflow, which builds the new version with
every tracked Telegraf release.

`telegraf_version` and `base_digest` in the `Rakefile` are only what CI tests a
version of ours with; each build passes its own. Point them at a newer Telegraf
whenever convenient, with `rake image:versions`'s counterpart for the base:
`docker buildx imagetools inspect telegraf:<version>-alpine`. Forgetting the
digest builds the _old_ release under the new name — Docker ignores the tag
when a digest is present — and `rake test` fails on the Telegraf version check.

### Adding a platform

The `platforms` list in the `Rakefile` and the `build` matrix in
`.github/workflows/ci.yml` are separate lists, on purpose — the workflow says
what it builds instead of computing it. Change both together.

## Releasing

`.github/workflows/release.yml` publishes a version of ours, as described in
"Building every Telegraf release". It fires on a release tag of ours,
`v[0-9]+.[0-9]+.[0-9]+` — never on a development version, which is never tagged
— checks that the tag matches the `Rakefile`, runs the full CI suite for that
commit, and then builds, verifies and pushes every new build with
`rake builds:publish`.

When `mirror.yml` dispatches it, the run skips the CI job: the tag was tested
when it was first released, and the publish job builds and verifies every build
it pushes anyway. A release a person starts, by tag or by dispatch, runs CI as
usual.

`image:publish` is a plain `docker push` of the image already in the local
daemon, not a second build to the registry. So the bytes that reach Docker Hub
are the ones `image:verify` just ran its checks against, rather than a rebuild
that ought to be identical. It refuses to push a tag that is absent or missing
a platform, which is why it is only ever the second half of `image:push`. And
it refuses a tag that is already on Docker Hub: `docker push` would replace it
silently, and whoever runs that tag would get different bytes on their next
pull. A build is made once; a change is a new version of ours, and so a new
build name.

It needs two secrets on the **`release` environment** — not repository secrets,
so that no branch build can reach them:

- `DOCKERHUB_USERNAME` — the Docker Hub account owning the namespace.
- `DOCKERHUB_TOKEN` — an access token for it, not the account password.

The publish job declares `environment: release`, which is what makes those
secrets visible to it, and the environment restricts itself to `v*` tags. CI
holds no Docker Hub credentials at all; it only pulls the public base image.

## Layout

- `Rakefile` — single source of truth (our version, the Telegraf version and
  base CI tests with, the tooling base, platforms, the Telegraf floor), the
  `image:*`, `builds:*`, `mirror:*` and `release` tasks and `rake lint`.
- `Dockerfile` — the image, plus its build-time assertions, the build stage for
  `node-tool`, and the test host `image:verify` runs against.
- `node-tool/` — the wrapper that runs the node's `smartctl`, LVM tools and
  `zpool` with their capabilities; a Rust crate with no dependencies.
- `examples/smartctl.conf`, `examples/smart.conf`, `examples/lvm.conf`,
  `examples/zfs.conf` — plugin configuration for the consumer to adapt; all are
  load-tested by `image:verify`.
- `.github/workflows/` — CI (build and verify per platform), release (publish)
  (build every Telegraf release with a version of ours) and mirror (run release
  on every version of ours daily).

## License

[MIT](LICENSE.txt), for the files in this repository. The image they build also
contains software under its own licenses — Telegraf (MIT) and the Alpine
packages of the base image. smartmontools, LVM and ZFS are the node's, not the
image's.
