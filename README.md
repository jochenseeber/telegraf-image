# Telegraf with smartmontools

A Telegraf container image that adds `smartmontools`, so Telegraf can collect
disk SMART attributes from Kubernetes nodes. Both SMART plugins work out of the
box: [`inputs.smartctl`][smartctl-plugin] and the older
[`inputs.smart`][smart-plugin].

Published as **`jochen/telegraf:1.40.0-alpine.0`**.

Versions are semantic: `1.40.0` is the upstream Telegraf release, and the
`alpine.0` prerelease names the variant and counts rebuilds of it. One string
serves everywhere — the image tag, the git tag (`v1.40.0-alpine.0`) and the
`org.opencontainers.image.version` label are the same characters, because the
format uses nothing Docker rejects in a tag.

[smartctl-plugin]: https://github.com/influxdata/telegraf/tree/master/plugins/inputs/smartctl
[smart-plugin]: https://github.com/influxdata/telegraf/tree/master/plugins/inputs/smart

## Why this image exists

The official Telegraf images cannot read SMART data. Both 1.40 Dockerfiles, the
Debian and the Alpine one, install `lm_sensors`, `iputils`, `net-snmp-tools`,
`procps`, `tzdata`, `setpriv`, `libcap` and `tini` — and no `smartmontools`. An
upstream request to add the package was opened in December 2021 and closed
without it landing.

## What it adds over upstream

Built on `telegraf:1.40.0-alpine`, pinned by digest, unmodified except for:

- **`smartmontools` `7.5-r0`** — `smartctl`, which both plugins call.
- **`zlib` `1.3.2-r1`** in place of the base's `1.3.2-r0`, which has
  CVE-2026-85091 (a heap overflow). The pin goes once the base ships the fix.
- **`ping` with `cap_net_raw` instead of setuid root.** It was the only setuid
  file in the image, and so the only path from uid 100 to uid 0 — which, in a
  privileged pod, is root on the node. It works exactly as before.
- **`/etc/telegraf` owned by root.** Upstream gives it to the `telegraf` user,
  which lets the running process rewrite its own configuration.

Plus two things that make the plugins work without further configuration:

- **File capabilities on `smartctl`**, so it reaches the hardware itself and
  Telegraf stays unprivileged. See "Capabilities, not sudo or root".
- A `/usr/bin/smartctl` symlink. Alpine installs the tool under `/usr/sbin`,
  which is where `inputs.smartctl` looks; `inputs.smart` defaults to `/usr/bin`
  instead, and without the symlink it finds nothing. A capability lives on the
  inode, so the symlink confers the same privileges.

`nvme-cli` is deliberately **not** installed. `smartctl` reads NVMe SMART
itself, so the only thing `nvme` added was `inputs.smart`'s vendor-specific log
pages — and to do that it had to carry `cap_sys_admin` of its own. See "Which
plugin".

`inputs.smartctl` needs `smartctl` 7.0 or newer for JSON output. This image
ships **smartmontools 7.5** (`smartctl 7.5 2025-04-30 r5714`).

The exposed ports and the `telegraf` user are inherited from upstream. The
entrypoint and command are replaced — see "Capabilities, not sudo or root".

## Which plugin

**`inputs.smartctl`** is the newer one and the better default. It parses
`smartctl`'s JSON output, and it reads NVMe devices through `smartctl` itself —
its documentation is explicit that, "contrary to the smart plugin, this plugin
does not use the `nvme-cli` package". Configuration:
[`examples/smartctl.conf`](examples/smartctl.conf).

**`inputs.smart`** is the older one. It works here, and it emits a different
metric and tag shape, so the two are not drop-in replacements for each other in
existing dashboards — that shape is the only reason left to choose it.
Configuration: [`examples/smart.conf`](examples/smart.conf).

What this image does **not** support is that plugin's `enable_extensions`,
which shells out to `nvme` for vendor-specific NVMe log pages (Intel and
friends). `nvme-cli` is not installed, so the option must stay unset. NVMe
SMART itself is unaffected — `smartctl` reads it either way; only the
vendor-specific pages are gone, and with them a second binary holding
`cap_sys_admin`.

Pick `inputs.smartctl` unless something already depends on `inputs.smart`'s
metrics.

## Capabilities, not sudo or root

Nothing here runs as root. The image declares `USER telegraf` and starts at uid
100; every privilege it needs sits on a binary as a file capability, sized to
what that binary's own ioctls require.

Upstream's `/entrypoint.sh` is therefore unused. It exists to start as root,
`setcap` the Telegraf binary and drop to uid 100 with `setpriv` — work that is
either done at build time here or handled by `USER`. Replacing it rather than
patching it means no fork of upstream shell code to re-check each release, no
`setcap` running on every container start, and `supplementalGroups` applied by
the runtime instead of merged by hand in shell.

On `smartctl`:

- **`cap_dac_override`** — opens the device nodes, which are `root:disk` and
  closed to uid 100. `/dev` comes from the host, so joining a group instead
  would depend on the host's `disk` GID matching this image's. Override rather
  than `cap_dac_read_search` because the hardware-RAID paths (`aacraid`,
  `megaraid`, `cciss`, Areca) open their device `O_RDWR`.
- **`cap_sys_rawio`** — `SG_IO` and ATA passthrough, for SATA and SAS SMART.
- **`cap_sys_admin`** — NVMe Get Log Page, which carries the SMART/health data.

On `telegraf` itself:

- **`cap_dac_read_search`** — lists another process's `/proc/<pid>/fd`, which
  is `dr-x------` owned by that process's user. It is what lets
  `inputs.procstat` report `num_fds` for processes Telegraf does not own.
  Counting descriptors only reads that directory, so `cap_sys_ptrace` — which
  governs resolving the symlinks inside it — is not required.
- **`cap_net_raw`, `cap_net_bind_service`** — what the upstream entrypoint used
  to grant at every start, preserved because that entrypoint no longer runs.

And on `ping`, **`cap_net_raw`**, replacing the setuid bit upstream ships.

This replaced a `sudo` package and a sudoers policy. The honest accounting: for
SATA and SAS it is a real reduction, `cap_sys_rawio` in place of full root. For
NVMe it is not much of one — the kernel permits unprivileged NVMe passthrough
for only five Identify variants (`nvme_admin_cmd_allowed` in
`drivers/nvme/host/ioctl.c`), the health log is not among them, and there is no
narrower capability than `cap_sys_admin` to ask for. So `smartctl` is close to
root on an NVMe node, and saying otherwise would be false comfort.

What the design does buy is a smaller surface: no sudoers file to get wrong,
one package fewer, and — since `nvme-cli` was dropped — one binary carrying
`cap_sys_admin` instead of two.

The one sharp edge is covered under "What the consumer has to provide": a
capability-bearing binary will not execute at all in a container that lacks
those capabilities.

## What the consumer has to provide

The image cannot grant itself device access. The pod running it needs:

- **`privileged: true`** in the container's security context — see below for
  why, and for the narrower alternative.
- **`/dev` mounted** from the host, so `smartctl --scan-open` finds the disks.
- **`use_sudo = false`** in whichever plugin is configured — the default. There
  is no `sudo` in this image; setting it true looks for a binary that is not
  installed and fails every read.

No `runAsUser` is needed. The image declares `USER telegraf` and starts as uid
100 directly, so unlike earlier revisions it never needs to begin as root.
`runAsNonRoot: true` is accurate and safe to set, and so is
**`readOnlyRootFilesystem: true`** — Telegraf writes nothing to the image, and
`image:verify` runs it with a read-only root to keep that true.

### The capability rule, and why it fails loudly

Every privileged binary here carries its capabilities with the effective bit
set, and `execve` refuses such a binary unless the caller can obtain _every_
capability in its permitted set. Measured: a default container has
`CapBnd: 00000000a80425fb`, and there the image does not start at all:

```text
[FATAL tini (7)] exec /usr/bin/telegraf failed: Operation not permitted
```

So a misconfigured security context fails immediately rather than quietly
dropping a metric. The complete set the container's bounding set must hold is
**six**: `DAC_OVERRIDE`, `DAC_READ_SEARCH`, `SYS_RAWIO`, `SYS_ADMIN`, `NET_RAW`
and `NET_BIND_SERVICE`. Leave out any one and the binary carrying it will not
execute — including the two network capabilities, which Telegraf itself holds.

**`allowPrivilegeEscalation: false` silently disables all of it.** It sets
`no_new_privs`, under which the kernel executes a capability-bearing binary but
does not grant its capabilities. Measured: `smartctl` starts, then fails with
`open device … failed: Permission denied`. Nothing fails at startup, so the
first symptom is missing metrics. Kubernetes refuses that flag alongside
`privileged: true`, but it is the usual default in the narrower configuration
below, so it has to be left off there deliberately.

### Why `privileged`, and what is narrower

`privileged: true` is not something the image needs. It is what Kubernetes
needs to let a container open the host's disk nodes at all: mounting `/dev` by
`hostPath` exposes the nodes, but the device cgroup still refuses to open them.
Measured with Docker, with all six capabilities and no `privileged`: a
bind-mounted disk node fails with `Operation not permitted`, while the same
node passed as a device opens and reads.

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
    add: [DAC_OVERRIDE, DAC_READ_SEARCH, SYS_RAWIO, SYS_ADMIN, NET_RAW, NET_BIND_SERVICE]
```

What that buys, compared with `privileged`: a bounding set of 6 capabilities
instead of all 41 — no `SYS_MODULE`, `SYS_BOOT`, `SYS_PTRACE` or `NET_ADMIN` —
seccomp left on rather than switched off, and the host's `/dev` no longer
visible wholesale. This configuration was verified with Docker; the device
plugin side was not.

Ready-to-adapt snippets are in [`examples/`](examples): `smartctl.conf` and
`smart.conf`.

## Building

Requires Docker with buildx, and — to build more than one platform locally —
Docker's containerd image store.

```bash
rake image:config    # show what would be built and published
rake image:build     # one multi-platform build, loaded locally
rake image:verify    # run the checks against each platform in it
rake image:push      # build, verify, then push exactly what was verified
```

`rake test` is `image:build` plus `image:verify`.

`image:build` produces a single multi-platform image under the tag it will be
published as, rather than a set of per-architecture tags — so what gets
verified is the artifact itself, not something that resembles it.
`image:verify` then reaches each architecture out of that one manifest list
with `docker run --platform`.

`image:verify` runs checks against each platform: the Telegraf version, that
`smartctl` and `zlib` are the pinned versions and `smartctl` can emit JSON,
that `nvme` is absent, that every privileged binary carries the expected
capabilities and no file is setuid or setgid, that both plugins' default paths
and `ping` run, that the configuration is not writable by uid 100, that a
capability actually takes effect for uid 100 rather than merely being recorded,
that the image runs as the `telegraf` user and its entrypoint reaches the
binary, that Telegraf loads each shipped example config, and that it does so on
a read-only root filesystem. The base image's digest is asserted through the
`org.opencontainers.image.base.digest` label.

### Versions are pinned, on purpose

The base image is pinned by digest, and every apk package to its exact version.
The tag (`1.40.2-alpine`, never `1.40-alpine` or `latest`) stays in the `FROM`
line as documentation only: a tag is mutable, and upstream rebuilds it in place
whenever Alpine moves, so a tag pin was the one input that could change without
a commit.

The flip side of exact pins is that fixes never arrive on their own. A security
fix in the base or a package reaches this image only as a new revision, so
something has to notice — `rake image:versions` shows when the base has been
rebuilt or a package has moved.

The CI runners are pinned too (`ubuntu-24.04`, not `ubuntu-latest`), so the
toolchain a build runs against does not change underneath it. That image ships
Docker 28, which has no `--platform` on `docker image inspect` — the Rakefile
falls back for exactly that case, and pinning here is what keeps the fallback
exercised on every run rather than quietly rotting.

## Mirroring upstream releases

New Telegraf releases and upstream rebuilds are picked up automatically.
`.github/workflows/mirror.yml` runs daily (and on demand) and keeps one
**release line** per upstream release:

- **branch `<version>-alpine.x`**, e.g. `1.40.2-alpine.x`, holding the files
  for that Telegraf release;
- **tags `v<version>-alpine.<revision>`** cut from it, each published as
  `jochen/telegraf:<version>-alpine.<revision>`.

It tracks every exact `X.Y.Z-alpine` tag upstream at or above the `floor` in
the `Rakefile` (`1.40.0`); older bases predate what the Dockerfile relies on,
and release candidates are not releases. For each, **oldest first**, it
compares the line's current `IMAGE` literal with what upstream offers now — the
tag's digest, and the newest version of each pinned package for that base. If
anything moved, it writes the next revision into the line, runs `rake test`,
and only then commits, tags, pushes and publishes. A new line starts at
revision `0`, forked from `main`.

Order is guaranteed by doing one version at a time and stopping at the first
failure: a later release never lands while an earlier one is broken, and the
next run retries from the same place. Each release also waits for its publish
run to finish before the next version starts. A failure is the signal that an
upstream release needs a human — fix the Dockerfile on that line's branch (or
on `main`, for a line that does not exist yet) and the next run carries on.

Two things a person still decides: the `floor`, and changes to the image
itself. A Dockerfile or tooling change on `main` reaches an existing line only
when merged into its branch and released by hand, as below.

```bash
rake mirror:plan                 # what is tracked, and each line's latest tag
DRY_RUN=true rake mirror:sync    # verify what would be released, change nothing
```

The workflow's own dry run (`workflow_dispatch` with `dry_run`) does the same
on a runner.

## Bumping the Telegraf version by hand

The mirror normally does this. By hand it is the same steps, which still apply
to `main` and to a release line being fixed.

Everything version-shaped lives in the `IMAGE` literal at the bottom of the
[`Rakefile`](Rakefile). The Dockerfile's `ARG` defaults mirror it so a bare
`docker build` works, and have to be updated alongside.

1. Check what is current:
   `docker run --rm telegraf:<new>-alpine telegraf --version`.
2. Set `telegraf_version` in that literal and reset `revision` to `0`.
3. Refresh the base digest and the package pins — a new Telegraf release often
   moves to a newer Alpine base with different package versions:

   ```bash
   rake image:versions
   ```

   It prints the tag's current digest, to copy into `base_digest`, then asks
   the new base image's own `apk` what it would install, for every configured
   platform, and prints the versions to copy into `packages`. The mirror pins
   each package to the newest version offered, which keeps the `zlib` security
   override current on its own.
4. Mirror the Telegraf version, the digest and the pins into the `Dockerfile`'s
   `ARG` defaults. Forgetting the digest builds the _old_ release under the new
   tag — Docker ignores the tag when a digest is present — and `rake test`
   fails on the Telegraf version check.
5. `rake test`, then commit.
6. Tag with the reference the `Rakefile` now expects and push the tag:

   ```bash
   git tag "$(rake --silent image:release_ref)"
   git push origin main --follow-tags
   ```

   The release workflow refuses any tag that disagrees with the `Rakefile`, so
   the code is always the authority and the tag follows it.

To rebuild without a Telegraf bump — a moved package pin, a capability change,
a base image rebuild (a new `base_digest` under the same tag) — leave
`telegraf_version` alone and increment `revision`, giving `-alpine.1`,
`-alpine.2` and so on. Those sort in order under semver, and all of them sort
below a bare `1.40.2`, which this project never publishes.

### Adding a platform

The `platforms` list in the `Rakefile` and the `build` matrix in
`.github/workflows/ci.yml` are separate lists, on purpose — the workflow says
what it builds instead of computing it. Change both together.

## Releasing

`.github/workflows/release.yml` fires on a `v*` tag. It checks that the tag
matches the `Rakefile`, runs the full CI suite for that commit, and only then
builds, verifies and pushes — the same `rake image:push` a workstation runs.

The mirror's tags reach it differently: a tag pushed with the workflow token
starts no workflows, so the mirror dispatches `release.yml` on the tag instead.
A dispatch on anything but a matching tag fails its tag check. Such a run skips
the CI job, because the mirror already built and verified that exact commit
before tagging it; the publish job still builds and verifies before it pushes.
A release a person starts, by tag or by dispatch, runs CI as usual.

`image:publish` is a plain `docker push` of the image already in the local
daemon, not a second build to the registry. So the bytes that reach Docker Hub
are the ones `image:verify` just ran its checks against, rather than a rebuild
that ought to be identical. It refuses to push a tag that is absent or missing
a platform, which is why it is only ever the second half of `image:push`.

It needs two secrets on the **`release` environment** — not repository secrets,
so that no branch build can reach them:

- `DOCKERHUB_USERNAME` — the Docker Hub account owning the namespace.
- `DOCKERHUB_TOKEN` — an access token for it, not the account password.

The publish job declares `environment: release`, which is what makes those
secrets visible to it, and the environment restricts itself to `v*` tags. CI
holds no Docker Hub credentials at all; it only pulls the public base image.

## Layout

- `Rakefile` — single source of truth (base version, revision, platforms,
  package pins, the mirror's floor), the `image:*` and `mirror:*` tasks and
  `rake lint`.
- `Dockerfile` — the image, plus its build-time assertions.
- `examples/smartctl.conf`, `examples/smart.conf` — plugin configuration for
  the consumer to adapt; both are load-tested by `image:verify`.
- `.github/workflows/` — CI (build and verify per platform), release (publish)
  and mirror (track upstream releases).

## License

[MIT](LICENSE.txt), for the files in this repository. The image they build also
contains software under its own licenses — Telegraf (MIT), smartmontools
(GPL-2.0-or-later), and the Alpine packages of the base image.
