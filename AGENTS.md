# Agent Instructions

Read [README.md](README.md) first — it covers why this image exists, the
root-versus-sudo decision, what consumers must provide, and how to bump the
Telegraf version. Everything below is only for agents and is not repeated
there.

## The one rule that matters here

The `IMAGE` literal at the bottom of the `Rakefile` is the single source of
truth for every version. It is the composition root: the only place that names
concrete versions, reads the environment (`IMAGE_PLATFORMS`) and wires the
objects together. `Image` itself is told everything at construction and is
frozen, so do not move configuration into constants on the class or have it
consult `ENV` — that is the design, not an accident.

When asked to bump anything, change that literal and run `rake test`.

Two places deliberately repeat what those constants say, and both must be
changed with them:

- the `Dockerfile`'s `ARG` defaults, so a bare `docker build` still works;
- the `build` matrix in `.github/workflows/ci.yml`, which states its platforms
  rather than computing them.

This duplication is a decision, not an oversight — do not reintroduce a
generated matrix or a separate manifest file to remove it. `rake image:verify`
catches a `Dockerfile` that has drifted (it asserts the installed versions and
the image labels against the constants). Nothing catches a CI matrix missing a
platform the `Rakefile` lists, which would then be published unverified, so
that is the pairing to be careful with.

## Do not "fix" these

They look like oversights and are not:

- **No `# syntax=` directive in the `Dockerfile`.** It would pull a frontend
  image from the registry at a floating `:1` tag, in a project whose point is
  that nothing floats. Nothing in the file needs it.
- **No `USER` instruction, and no override of `ENTRYPOINT`.** The upstream
  entrypoint drops from root to `telegraf` itself. Setting `USER` skips that
  drop and breaks sudo, because the sudoers policy names the `telegraf` user.
- **Exact apk pins that eventually stop resolving.** A failing build is the
  intended signal that Alpine rotated a version out of its index. Fix it with
  `rake image:versions` and a `REVISION` bump, not by unpinning.
- **Each tool listed twice in `sudoers.d/telegraf`.** sudo matches command
  paths literally, not after resolving symlinks, so `/usr/bin/smartctl` needs
  its own rule even though it points at `/usr/sbin/smartctl`. Verified, not
  assumed — deleting either pair breaks one of the two plugins.
- **The `/usr/bin` symlinks.** `inputs.smartctl` looks in `/usr/sbin`,
  `inputs.smart` in `/usr/bin`. The symlinks are what let both plugins work
  without every consumer overriding `path_smartctl` and `path_nvme`.
- **Everything in one `Rakefile`** — `Image`, `CommandRunner`, `WorkflowLinter`
  and the value types. There is no `rakelib/`. `.rubocop.yml` excludes the
  `Rakefile` from `Style/OneClassPerFile` for exactly this reason.
- **No rescue around the task bodies.** Rake already aborts with exit 1 and
  prints the exception message; a wrapper would only hide the backtrace, which
  matters when the failure is a bug rather than a bad pin.
- **`runs-on: ubuntu-24.04`, not `ubuntu-latest`.** Pinned like everything else
  here, and deliberately on the image shipping Docker 28 — the version with no
  `--platform` on `docker image inspect`, which is the path
  `Image#inspect_image` falls back for. Moving to a newer runner leaves that
  fallback untested.
- **No Docker Hub login in CI.** It pulls only the public base image. The push
  token stays out of a workflow that runs on every branch.
- **`environment: release` on the publish job.** The Docker Hub credentials are
  environment secrets, and an environment secret reaches only a job that names
  its environment. Removing that line does not fall back to repository secrets
  — it makes them resolve to empty, and the login fails on "Username and
  password required".
- **The image tag joins build metadata with `-`, the git tag with `+`.** Not an
  inconsistency: `Image#version` is the one semantic version, and Docker's
  reference parser rejects `+`, so `Image#tag` transliterates it. Do not
  "unify" them by putting `-` in the git tag or dropping the metadata. The
  transliteration is one-way — recover a version from the
  `org.opencontainers.image.version` label, never by parsing the tag.

## Verification

`rake image:verify` is not optional before publishing, and it must keep testing
every platform the image is configured for, not just the host's. Several of its
checks exist because their failure mode is otherwise invisible — a metrics gap
on a node, days later:

- the `telegraf` user reaching `smartctl`/`nvme` through sudo, at both plugins'
  default paths,
- the entrypoint still dropping to uid 100, and
- Telegraf actually loading each config under `examples/`.

The example configs are shipped documentation that is also executed: `--test`
rejects an option the installed Telegraf does not have, so those two checks are
what keeps `examples/` from drifting. Adding an option to an example without
running `rake image:verify` defeats the point.

The entrypoint check deliberately runs through the image's real `ENTRYPOINT`.
Rewriting it to run under `--entrypoint /bin/sh` would make it pass on an image
that never drops privileges at all.

`image:publish` is a plain `docker push` of the already-loaded image, on
purpose: the published bytes are the verified ones. Do not turn it back into a
`buildx --push`, which would publish a rebuild that only ought to match what
was checked. Its refusal to push a missing or partially built tag is what keeps
that guarantee, so the guard is not redundant with `image:push`'s task order.

Report what `rake image:verify` actually printed. It names the versions it
found, so quoting them is cheap and a claim without them is not verification.

## Workspace state

**This project is detached from vsrun facet management.** There is no
`.project.yaml`, so `vsrun --config` has no facets to apply here. Every config
file in the tree — `.rubocop.yml`, `.gitignore`, `Gemfile`, `cspell.yaml`,
`dprint.json`, `.markdownlint.yaml`, `.vscode/` — is owned by this project and
edited directly. Do not reintroduce `.project.yaml` or move code back into a
`rakelib/` directory to match the shared facets.

Some of those files were originally generated by the facets and still read that
way; they are ordinary project files now, and changing one is a normal edit
rather than something to push upstream.

Markdown is formatted with `dprint fmt`.
