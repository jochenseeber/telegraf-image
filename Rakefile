# frozen_string_literal: true

require "English"
require "fileutils"
require "json"
require "net/http"
require "time"
require "tmpdir"

# Run external commands
class CommandRunner
  include Rake::DSL

  # Print command to console and run; options such as `chdir:` go to spawn
  def execute(*, **)
    sh(*, **)
  end

  # Run command, capture stdout and return `nil` on failure
  def capture(*arguments, **)
    output = IO.popen(arguments, err: File::NULL, **, &:read)
    $CHILD_STATUS.success? ? output : nil
  end

  # Run command, capture stdout and stderr, and return `nil` on failure
  def capture_merged(*)
    output, succeeded = run_merged(*)
    succeeded ? output : nil
  end

  # Run command, capture stdout and stderr, and return them with whether it
  # succeeded: for failures whose output says why
  def run_merged(*arguments)
    output = IO.popen(arguments, err: %i[child out], &:read)
    [output, $CHILD_STATUS.success?]
  end
end

# Docker image handling
class Image
  # Platform information
  Platform = Data.define(:operating_system, :architecture) do
    def self.parse(text)
      operating_system, architecture = text.to_s.split("/", 2)
      if operating_system.to_s.empty? || architecture.to_s.empty?
        raise ArgumentError, "expected an os/arch platform, got #{text.inspect}"
      end

      new(operating_system: operating_system, architecture: architecture)
    end

    def to_s
      "#{operating_system}/#{architecture}"
    end
  end

  # Label for Docker builds
  Label = Data.define(:name, :value)

  # Argument for Docker builds
  BuildArgument = Data.define(:name, :value) do
    def to_argument
      "#{name}=#{value}"
    end
  end

  # Assertion about the built image
  #
  # `expected` is a substring rather than a regexp because these assert
  # versions, and a failing literal prints a diff worth reading.
  #
  # `via_entrypoint` runs the image's own ENTRYPOINT. `on_host` runs it as the
  # telegraf user against the test host, the way a pod runs on a node.
  Check = Data.define(:description, :command, :expected, :via_entrypoint, :mount, :user, :read_only, :tmpfs,
                      :on_host) do
    def docker_arguments(reference:, platform:, host: nil)
      # Privileged, because that is how the image is deployed and because it is
      # now required rather than merely expected: the tools carry file
      # capabilities with the effective bit set, and execve refuses them unless
      # the container's bounding set holds every one. A default container
      # cannot even run `smartctl --version`.
      arguments = ["run", "--rm", "--privileged", "--platform", platform.to_s]
      # The image runs as the telegraf user, so a check that has to set up
      # root-owned state says so rather than reaching for su.
      arguments += ["--user", user] if user
      arguments << "--read-only" if read_only
      arguments += tmpfs.flat_map { |mount| ["--tmpfs", mount] }
      arguments += ["--volume", "#{File.expand_path(mount)}:/#{File.basename(mount)}:ro"] if mount
      return [*arguments, *on_host_arguments(host, reference)] if on_host
      # Through the entrypoint the command is the container's arguments; around
      # it, a shell is substituted so a check can use a pipeline or a `su`.
      return [*arguments, reference, *command.split] if via_entrypoint

      [*arguments, "--entrypoint", "/bin/sh", reference, "-c", command]
    end

    # What a pod gets: the node's /proc at /hostfs/proc. Here that is a /proc
    # mounted inside the test host's process namespace, which the check joins,
    # so process 1 in it is the test host's init. Joining also makes the
    # node's /proc know the check's processes, as a node's does a pod's, which
    # LVM needs after entering to find sysfs. Mounting a /proc takes root, so
    # root sets it up, on a tmpfs that keeps a read-only root possible, and the
    # check itself runs as telegraf; it arrives as an argument, unquoted.
    def on_host_arguments(host, reference)
      raise Error, "#{description}: needs the test host, which is not running" if host.nil?

      ["--pid", "container:#{host.id}", "--tmpfs", "/hostfs", "--user", "0:0",
       "--entrypoint", "/bin/sh", reference, "-c",
       "mkdir -p /hostfs/proc && mount -t proc proc /hostfs/proc && exec su telegraf -s /bin/sh -c \"$1\"",
       "sh", command,]
    end

    def result_for(output, succeeded: true)
      raise Error, "#{description}: command failed: #{command}\n#{output}" unless succeeded
      unless output.include?(expected)
        raise Error, "#{description}: expected #{expected.inspect} in output of " \
                     "#{command.inspect}, got:\n#{output}"
      end

      # The matching line, not the first: several of these print JSON or a
      # banner whose first line carries nothing.
      matching_line = output.lines.find { |line| line.include?(expected) } || output.lines.first
      matching_line.to_s.strip
    end
  end

  # The running test host's container
  TestHost = Data.define(:id)

  class Error < StandardError; end

  DOCKERFILE = "Dockerfile"

  # Device nodes as a real host has them. Docker Desktop hands containers a
  # world-writable /dev/mapper/control, where a host keeps it root-only and
  # 0600 — and LVM opens it read-write, so on Docker Desktop a capability set
  # too weak for any real node passes. Container-local: a container's /dev is
  # its own tmpfs. Needs root, so the LVM work itself runs through su.
  #
  # /dev/zfs too, where the Docker host's kernel has the ZFS module: a node
  # may keep it 0600, so zpool must cope with that, as it does on CI.
  AS_ON_A_HOST = "chown root:root /dev/mapper/control && chmod 0600 /dev/mapper/control && " \
                 "if [ -e /dev/zfs ]; then chown root:root /dev/zfs && chmod 0600 /dev/zfs; fi"

  # Part of every `smartctl --version`, and of nothing node-tool says itself.
  SMARTCTL_BANNER = "www.smartmontools.org"

  # The test host's life: a throwaway volume group on a loop device, with
  # the loop node at root:disk 0660 like a real disk and the device-mapper
  # control node as a host has it, then idle until stopped. Teardown runs from
  # the trap, whether the checks passed or not.
  TEST_HOST_SCRIPT = <<~SH.freeze
    set -eu
    img=/tmp/pv.img
    truncate -s 64M "$img"
    loop=$(losetup -f)
    losetup "$loop" "$img"
    trap 'vgremove -f -q imagecheck >/dev/null 2>&1 || true; losetup -d "$loop" || true; exit 0' TERM INT
    pvcreate -q "$loop"
    vgcreate -q imagecheck "$loop"
    lvcreate -q -y -Zn -L 8M -n probe imagecheck 2>/dev/null
    chown root:disk "$loop"
    chmod 0660 "$loop"
    #{AS_ON_A_HOST}
    touch /tmp/ready
    sleep 3600 &
    wait
  SH

  SEMVER = %r{\A\d+\.\d+\.\d+\z}
  # Ours may also be a development version, `X.Y.Z-dev`: what `main` and a
  # release branch carry between releases. Only a release commit is `X.Y.Z`.
  OWN_VERSION = %r{\A\d+\.\d+\.\d+(-dev)?\z}
  DIGEST = %r{\Asha256:\h{64}\z}

  attr_reader :repository, :own_version, :telegraf_version, :base_digest, :tooling_base, :tooling_digest,
              :platforms

  def initialize(repository:, own_version:, telegraf_version:, base_digest:, tooling_base:, tooling_digest:,
                 platforms:, build_cache: nil, commands: CommandRunner.new, registry: Registry.new)
    raise ArgumentError, "an image needs at least one platform" if platforms.empty?
    raise ArgumentError, "own_version must be X.Y.Z or X.Y.Z-dev, got #{own_version.inspect}" \
      unless own_version.match?(OWN_VERSION)
    raise ArgumentError, "telegraf_version must be X.Y.Z, got #{telegraf_version.inspect}" \
      unless telegraf_version.match?(SEMVER)

    { base_digest: base_digest, tooling_digest: tooling_digest }.each do |name, digest|
      raise ArgumentError, "#{name} must be sha256:<64 hex>, got #{digest.inspect}" unless digest.match?(DIGEST)
    end

    @repository = repository
    @own_version = own_version
    @telegraf_version = telegraf_version
    @base_digest = base_digest
    @tooling_base = tooling_base
    @tooling_digest = tooling_digest
    @platforms = platforms.freeze
    @build_cache = build_cache&.dup&.freeze
    @commands = commands
    @registry = registry
    freeze
  end

  def with_platforms(platforms)
    unknown = platforms - @platforms
    raise Error, "#{unknown.join(", ")} is not a platform this image is configured for" unless unknown.empty?

    copy(platforms: platforms)
  end

  # Builds reusing the layers of earlier ones from a directory, which CI keeps
  # between runs. Only for checking: a release builds from scratch.
  def with_build_cache(directory)
    copy(build_cache: directory)
  end

  # The same version of ours, built on another Telegraf release. Nothing is
  # written: the release and its base reach the build as arguments only.
  def with_telegraf(telegraf_version:, base_digest:)
    copy(telegraf_version: telegraf_version, base_digest: base_digest)
  end

  # The build's name: the Telegraf release it is built on, then this project's
  # version as semver build metadata, labelled `image.` so the name says which
  # version is which — `1.40.2+image.1.0.0`. Telegraf's comes first because it
  # is what consumers choose by. The git tag, the release branch and the
  # version label use it as it is.
  def version
    "#{@telegraf_version}+image.#{@own_version}"
  end

  # Docker rejects `+` in a tag, so the image tag swaps it for `_`, which no
  # version contains: `1.40.2_image.1.0.0`. One way only — recover a version from the
  # version label, never by parsing a tag.
  def tag
    version.tr("+", "_")
  end

  def reference
    "#{@repository}:#{tag}"
  end

  def base_image
    "telegraf:#{@telegraf_version}-alpine"
  end

  # The tag a build is released from: our version's, `v1.0.0`. Every build of
  # that version, whatever its Telegraf, comes from it.
  def release_reference
    "v#{@own_version}"
  end

  def build
    ensure_multi_platform_loadable
    build_target("image", reference)
    build_target("test-host", test_host_reference)
  end

  # The stand-in node `verify` runs the node-tool checks against. Under a name of its
  # own, outside the repository, so it cannot be pushed as the image.
  def test_host_reference
    "local/telegraf-test-host:#{tag}"
  end

  def verify
    image_checks = checks
    @platforms.each do |platform|
      ensure_contains(platform, action: "run `rake image:build` first")
      puts "#{platform} (#{reference})"
      with_test_host(platform) do |host|
        image_checks.each do |check|
          puts "  #{check.description}: #{run_check(check, platform: platform, host: host)}"
        end
      end
      verify_labels(platform: platform)
      verify_numeric_user(platform: platform)
    end
    puts "#{image_checks.size + labels.size + 1} checks passed on #{@platforms.size} platform(s)"
  end

  # Never over an existing tag: `docker push` would replace it silently, and
  # whoever runs that tag would get different bytes on their next pull. A build
  # is made once; a change is a new version of ours.
  def publish
    @platforms.each do |platform|
      ensure_contains(platform, action: "run `rake image:build` and `rake image:verify` first")
    end
    raise Error, "#{reference} is already published; builds are never replaced" unless @registry.digest(@repository, tag).nil?

    @commands.execute("docker", "push", reference)
  end

  # For bumping the pins: the current digests of the tooling base and of this
  # checkout's Telegraf base, next to the pinned ones.
  def report_available_versions
    { @tooling_base => @tooling_digest, base_image => @base_digest }.each do |image, pinned|
      digest = @commands.capture("docker", "buildx", "imagetools", "inspect", image,
                                 "--format", "{{.Manifest.Digest}}")
      raise Error, "cannot read the current digest of #{image}" if digest.nil?

      puts "=== #{image} ==="
      puts "current digest: #{digest.strip}"
      puts "pinned digest:  #{pinned}"
    end
  end

  def describe
    puts "version:      #{version}"
    puts "publishes:    #{reference}"
    puts "release tag:  #{release_reference}"
    puts "base image:   #{base_image}@#{@base_digest}"
    puts "tooling base: #{@tooling_base}@#{@tooling_digest}"
    puts "platforms:    #{@platforms.join(", ")}"
  end

  def build_arguments
    [
      BuildArgument.new(name: "TELEGRAF_VERSION", value: @telegraf_version),
      BuildArgument.new(name: "BASE_DIGEST", value: @base_digest),
      BuildArgument.new(name: "TOOLING_BASE", value: @tooling_base),
      BuildArgument.new(name: "TOOLING_DIGEST", value: @tooling_digest),
      BuildArgument.new(name: "IMAGE_VERSION", value: version),
      BuildArgument.new(name: "SOURCE_COMMIT", value: source_commit),
    ]
  end

  def labels
    [
      Label.new(name: "org.opencontainers.image.base.name", value: "docker.io/library/#{base_image}"),
      Label.new(name: "org.opencontainers.image.base.digest", value: @base_digest),
      Label.new(name: "org.opencontainers.image.version", value: version),
    ]
  end

  # Image checks, grouped by what they prove
  def checks
    content_checks + privilege_checks + behaviour_checks
  end

  private

  def copy(**changes)
    arguments = { repository: @repository, own_version: @own_version, telegraf_version: @telegraf_version,
                  base_digest: @base_digest, tooling_base: @tooling_base, tooling_digest: @tooling_digest,
                  platforms: @platforms, build_cache: @build_cache, commands: @commands, registry: @registry, }
    self.class.new(**arguments, **changes)
  end

  # What is installed, and at which version
  def content_checks
    [
      check("Telegraf version",
            command: "telegraf --version", expected: "Telegraf #{@telegraf_version}"),
      # None of the tools this image adds plugins for: smartctl, the LVM tools
      # and zpool are the node's, run through node-tool. Asserted against their
      # packages returning as dependencies — present, and quietly run instead
      # of the node's. nvme-cli too: smartctl reads NVMe SMART itself.
      check("smartmontools, LVM, ZFS and nvme-cli absent",
            command: "test -z \"$(apk info -e smartmontools lvm2 zfs nvme-cli)\" && echo absent", expected: "absent"),
      # Static, because it carries capabilities: with no dynamic loader in play,
      # nothing in the environment can change what code it runs.
      check("node-tool is statically linked",
            command: "test -z \"$(scanelf -qn /usr/libexec/node-tool)\" && echo static", expected: "static"),
    ]
  end

  # Who holds which privilege, and that nothing else does
  def privilege_checks
    [
      check("telegraf carries its capability",
            command: "getcap /usr/bin/telegraf",
            expected: "cap_dac_read_search,cap_net_bind_service,cap_net_raw=ep"),
      check("ping carries a capability instead of setuid",
            command: "getcap /bin/ping", expected: "cap_net_raw=ep"),
      # Permitted only: the entry capabilities are effective for opening the
      # node's namespace and one setns call, each tool's own only as ambient
      # capabilities in the node's tool. Asserted on the real path: `getcap`
      # does not follow the links that lead to it.
      check("node-tool carries its capabilities, permitted only",
            command: "getcap /usr/libexec/node-tool",
            expected: "cap_dac_override,cap_fowner,cap_sys_rawio,cap_sys_chroot,cap_sys_ptrace,cap_sys_admin=p"),
      # Upstream ships ping setuid root, and in a privileged pod uid 0 is root on
      # the node, so no path from uid 100 to uid 0 may exist. Root runs the
      # search because uid 100 cannot descend into /root.
      check("no setuid or setgid files",
            command: "test -z \"$(find / -xdev -type f -perm /6000)\" && echo none",
            expected: "none", user: "0:0"),
      # Upstream gives /etc/telegraf to the telegraf user, which would let the
      # running process rewrite its own configuration.
      check("uid 100 cannot write the configuration",
            command: "(touch /etc/telegraf/telegraf.conf || touch /etc/telegraf/telegraf.d/probe) " \
                     "2>/dev/null && echo writable || echo denied",
            expected: "denied"),
      # Proves a capability is live rather than merely recorded — a
      # recorded-but-inert xattr looks identical from `getcap`. Needs root to
      # lay out the probe.
      check("a capability actually takes effect for uid 100",
            command: "cp /bin/busybox /tmp/busybox && setcap cap_dac_override+ep /tmp/busybox && " \
                     "printf live > /root/probe && chmod 600 /root/probe && " \
                     "su telegraf -s /bin/sh -c '/tmp/busybox cat /root/probe'",
            expected: "live", user: "0:0"),
      check("image runs as the telegraf user",
            command: "id", expected: "uid=100(telegraf)"),
    ]
  end

  # That it all works for uid 100. No `su` here: the image runs as the telegraf
  # user, so these already are that user — and on_host checks are run as it.
  def behaviour_checks
    [
      check("ping runs for uid 100",
            command: "ping -c 1 -W 1 127.0.0.1", expected: "1 received"),
      # The image has none of these tools, so their own output — not
      # node-tool's messages, which never contain it — is proof the node's ran.
      check("inputs.smartctl path runs the node's smartctl",
            command: "/usr/sbin/smartctl --version", expected: SMARTCTL_BANNER, on_host: true),
      check("inputs.smart path runs the node's smartctl",
            command: "/usr/bin/smartctl --version", expected: SMARTCTL_BANNER, on_host: true),
      check("the node's smartctl emits JSON",
            command: "/usr/sbin/smartctl --json --scan-open", expected: '"json_format_version"', on_host: true),
      check("inputs.lvm paths run the node's LVM",
            command: "/usr/sbin/pvs --version && /usr/sbin/vgs --version && /usr/sbin/lvs --version",
            expected: "LVM version:", on_host: true),
      # The image has no zpool, so any answer from one is the node's. Without
      # the ZFS kernel module, which no container can load, the test host's
      # answers that it cannot load it; a runner that has it loaded answers
      # with versions, through a /dev/zfs kept 0600 as a node may keep it.
      # Both prove node-tool reached the node's zpool.
      check("the zpool path runs the node's zpool",
            command: "out=$(/usr/sbin/zpool version 2>&1); case \"$out\" in " \
                     "*zfs-*|*'ZFS modules'*) echo \"node's zpool answered: $out\" ;; *) echo \"$out\" ;; esac",
            expected: "node's zpool answered", on_host: true),
      *refusal_checks,
      # The privilege model is declarative rather than something the entrypoint
      # performs, so it is worth asserting that the entrypoint reaches the
      # binary at all.
      check("entrypoint runs telegraf",
            command: "--version", expected: "Telegraf #{@telegraf_version}", via_entrypoint: true),
      check("examples/smartctl.conf loads",
            command: "telegraf --config /examples/smartctl.conf --test",
            expected: "Loaded inputs: smartctl\n", mount: "examples", on_host: true),
      check("examples/smart.conf loads",
            command: "telegraf --config /examples/smart.conf --test",
            expected: "Loaded inputs: smart\n", mount: "examples", on_host: true),
      check("examples/lvm.conf loads",
            command: "telegraf --config /examples/lvm.conf --test",
            expected: "Loaded inputs: lvm\n", mount: "examples", on_host: true),
      check("examples/zfs.conf loads",
            command: "telegraf --config /examples/zfs.conf --test 2>&1",
            expected: "Loaded inputs: exec zfs\n", mount: "examples", on_host: true),
      zpool_parsing_check,
      # README.md promises readOnlyRootFilesystem works; this is what keeps that
      # true rather than true once. The node's tools write, if anything, in the
      # node's mount namespace, so a read-only root needs nothing extra. /tmp
      # is for Rosetta, which runs amd64 on Apple silicon and needs a writable
      # temp directory to start an emulated binary at all.
      check("telegraf runs on a read-only root filesystem",
            command: "telegraf --config /examples/smartctl.conf --test",
            expected: "Loaded inputs: smartctl\n", mount: "examples", read_only: true, tmpfs: ["/tmp"],
            on_host: true),
      # LVM's stderr is kept, minus two notices it always prints here, so a
      # failure says why. A report with warnings passes: under QEMU, as arm64
      # runs in CI, LVM warns that it falls back from async to sync I/O, which
      # is harmless. Errors fail.
      check("lvm runs on a read-only root filesystem",
            command: "out=$(vgs --reportformat json 2>&1 | grep -v -e 'as a non-root user' -e 'leaked on vgs' " \
                     "| tr -d ' \\n') && " \
                     "case \"$out\" in *'\"log_type\":\"error\"'*) echo \"$out\" ;; " \
                     "*'{\"report\":[{\"vg\":'*) echo \"reported without errors: $out\" ;; *) echo \"$out\" ;; esac",
            expected: "reported without errors", read_only: true, tmpfs: ["/tmp"], on_host: true),
      live_lvm_check,
    ]
  end

  # What node-tool is for: anything but reporting is refused before the node's
  # tool runs, with the capabilities never raised. These need no node.
  def refusal_checks
    [
      check("node-tool refuses other commands",
            command: "ln -s /usr/libexec/node-tool /tmp/lvcreate && /tmp/lvcreate -y -L 4M -n x vg || true",
            expected: "lvcreate: only pvs, vgs, lvs, smartctl and zpool are allowed"),
      check("node-tool refuses LVM options inputs.lvm does not pass",
            command: "/usr/sbin/lvs --config 'global{}' || true", expected: "lvs: argument not allowed: --config"),
      check("node-tool refuses smartctl self-tests",
            command: "/usr/sbin/smartctl -t short /dev/sda || true", expected: "smartctl: argument not allowed: -t"),
      check("node-tool refuses smartctl settings",
            command: "/usr/sbin/smartctl -s on /dev/sda || true", expected: "smartctl: argument not allowed: -s"),
      check("node-tool refuses zpool beyond listing",
            command: "/usr/sbin/zpool destroy tank || true", expected: "zpool: argument not allowed: destroy"),
      # Device arguments are paths under /dev, so a privileged smartctl cannot be
      # pointed at an arbitrary file.
      check("node-tool refuses smartctl paths outside /dev",
            command: "/usr/sbin/smartctl --all /dev/../etc/shadow || true",
            expected: "smartctl: argument not allowed: /dev/../etc/shadow"),
      # Without the node's /proc there is no node to enter, and the container's
      # own /usr/sbin/lvs would be the wrapper itself.
      check("node-tool refuses to run without the node's /proc",
            command: "/usr/sbin/lvs || true", expected: "lvs: mount the node's /proc at /hostfs/proc"),
      # The container's own /proc in its place must not loop either: there the
      # node's lvs would be the wrapper itself. Root only for the mount.
      check("node-tool refuses the container's own namespace",
            command: "mkdir -p /hostfs/proc && mount -t proc proc /hostfs/proc && " \
                     "su telegraf -s /bin/sh -c '/usr/sbin/lvs 2>&1' || true",
            expected: "lvs: /hostfs/proc/1/ns/mnt is this container's own namespace, not the node's", user: "0:0"),
    ]
  end

  # No container can create a pool, so the example's parsing of `zpool list`
  # is proven against a stand-in zpool printing what the real one does: the
  # same tab-separated columns, with "-" where a value does not apply. Pool and
  # health must arrive as the only tags besides host: a string field would be
  # dropped by outputs that take numbers only.
  def zpool_parsing_check
    stand_in = "#!/bin/sh\nprintf 'tank\\tDEGRADED\\t1000\\t400\\t600\\t-\\t40\\t1.00\\n'\n"
    check("examples/zfs.conf parses zpool list",
          command: "printf \"#{stand_in}\" > /tmp/zpool && chmod 755 /tmp/zpool && " \
                   "sed 's#/usr/sbin/zpool list[^\"]*#/tmp/zpool#' /examples/zfs.conf > /tmp/zfs.conf && " \
                   "telegraf --config /tmp/zfs.conf --test --input-filter exec 2>&1 | grep '^> zfs_pool,' | " \
                   "sed 's/,host=[^,]*//'",
          expected: "zfs_pool,health=DEGRADED,pool=tank ", mount: "examples")
  end

  # The whole path, end to end: the shipped example, read by the real plugin as
  # uid 100, against the test host's throwaway volume group. The test host set
  # its disk and control nodes up as a real node has them.
  def live_lvm_check
    check("inputs.lvm reads the node's volume group as uid 100",
          command: "telegraf --config /examples/lvm.conf --test 2>&1 | grep '^> lvm_logical_vol,'",
          expected: "name=probe,vol_group=imagecheck", mount: "examples", on_host: true)
  end

  def check(description, command:, expected:, via_entrypoint: false, mount: nil, user: nil, read_only: false,
            tmpfs: [], on_host: false)
    Check.new(description: description, command: command, expected: expected,
              via_entrypoint: via_entrypoint, mount: mount, user: user, read_only: read_only, tmpfs: tmpfs,
              on_host: on_host)
  end

  def build_target(target, tag)
    @commands.execute("docker", "buildx", "build",
                      "--platform", @platforms.join(","),
                      "--file", DOCKERFILE,
                      "--target", target,
                      *build_arguments.flat_map { |argument| ["--build-arg", argument.to_argument] },
                      *cache_arguments(target),
                      "--tag", tag,
                      "--load", ".")
    rotate_cache(target)
  end

  # Every stage's layers, written beside the cache read from and swapped in
  # afterwards: buildx's local cache only ever grows when written in place.
  def cache_arguments(target)
    return [] if @build_cache.nil?

    from = File.join(@build_cache, target)
    reading = File.directory?(from) ? ["--cache-from", "type=local,src=#{from}"] : []
    [*reading, "--cache-to", "type=local,dest=#{from}.new,mode=max"]
  end

  def rotate_cache(target)
    return if @build_cache.nil?

    current = File.join(@build_cache, target)
    FileUtils.rm_rf(current)
    FileUtils.mv("#{current}.new", current)
  end

  # Runs the test host for one platform with a throwaway volume group, yields
  # it, and stops it afterwards whatever happened. Its own trap
  # removes the volume group and loop device on stop: they are kernel state on
  # the Docker host, not the container's.
  def with_test_host(platform)
    host = @commands.capture("docker", "run", "--detach", "--rm", "--privileged",
                             "--platform", platform.to_s, "--pull", "never",
                             "--entrypoint", "/bin/sh", test_host_reference, "-c", TEST_HOST_SCRIPT)&.strip
    raise Error, "cannot start #{test_host_reference} for #{platform}; run `rake image:build` first" if host.to_s.empty?

    begin
      wait_for_test_host(host)
      yield TestHost.new(id: host)
    ensure
      @commands.capture("docker", "stop", "--time", "20", host)
    end
  end

  def wait_for_test_host(host)
    60.times do
      return if @commands.capture("docker", "exec", host, "test", "-e", "/tmp/ready")

      sleep 0.5
    end
    log = @commands.capture_merged("docker", "logs", host)
    raise Error, "the test host did not get ready:\n#{log}"
  end

  def run_check(check, platform:, host: nil)
    output, succeeded = @commands.run_merged("docker",
                                             *check.docker_arguments(reference: reference, platform: platform,
                                                                     host: host))
    check.result_for(output, succeeded: succeeded)
  end

  def verify_labels(platform:)
    output = inspect_image("{{json .Config.Labels}}", platform: platform)
    raise Error, "cannot read #{platform} labels from #{reference}" if output.nil?

    actual = JSON.parse(output.strip)
    labels.each do |label|
      found = actual[label.name]
      raise Error, "label #{label.name}: expected #{label.value.inspect}, got #{found.inspect}" unless found == label.value

      puts "  #{label.name}: #{found}"
    end
  end

  # The kubelet enforces runAsNonRoot only for a numeric user; with a name it
  # refuses to start the container. A uid with an optional numeric group.
  def verify_numeric_user(platform:)
    output = inspect_image("{{.Config.User}}", platform: platform)
    raise Error, "cannot read the #{platform} user from #{reference}" if output.nil?

    user = output.strip
    raise Error, "image user: expected a numeric uid for runAsNonRoot, got #{user.inspect}" unless user.match?(%r{\A\d+(:\d+)?\z})

    puts "  image user is numeric: #{user}"
  end

  def ensure_contains(platform, action:)
    return if contains?(platform)

    raise Error, "#{reference} has no #{platform} image; #{action}"
  end

  # Whether the tag holds an image for this platform — answered by starting
  # one, not by inspecting it.
  #
  # `docker image inspect --platform` exists only from Docker 29, and without
  # it the daemon reports the tag's *host* platform even when the tag is a
  # manifest list. Docker 28 with the containerd image store is exactly that
  # combination, and exactly what the release job builds, so inspection would
  # declare every non-host platform missing. Running the image is the one
  # question every version and image store answers alike; `--pull never` keeps
  # a missing platform a local answer rather than a registry round trip.
  def contains?(platform)
    !@commands.capture("docker", "run", "--rm", "--pull", "never", "--platform", platform.to_s,
                       "--entrypoint", "/bin/true", reference).nil?
  end

  # Labels, per platform where the daemon can do it. Docker 28 cannot: it
  # reports the host platform's config for a manifest list, so there the check
  # reads one platform's labels for every platform. They are built from the
  # same arguments and are expected to agree, so it degrades from "each
  # platform's labels" to "the labels" — weaker, never wrong.
  def inspect_image(format, platform:)
    @commands.capture("docker", "image", "inspect", "--platform", platform.to_s,
                      "--format", format, reference) ||
      @commands.capture("docker", "image", "inspect", "--format", format, reference)
  end

  def ensure_multi_platform_loadable
    return if @platforms.size < 2 || containerd_image_store?

    raise Error, "loading a #{@platforms.size}-platform image into the local daemon requires Docker's " \
                 "containerd image store, which this daemon does not use. Enable it in Docker Desktop " \
                 "(Settings > General > \"Use containerd for pulling and storing images\"), or build one " \
                 "platform at a time with IMAGE_PLATFORMS=#{@platforms.first}"
  end

  def containerd_image_store?
    @commands.capture("docker", "info", "--format", "{{json .DriverStatus}}")
      .to_s.include?("io.containerd.snapshotter")
  end

  # "unknown" rather than an abort, so the image still builds outside a checkout.
  def source_commit
    @commands.capture("git", "rev-parse", "HEAD")&.strip || "unknown"
  end
end

# GitHub Actions workflow linting
class WorkflowLinter
  def initialize(directory: ".github/workflows", tool: "actionlint", commands: CommandRunner.new)
    @directory = directory
    @tool = tool
    @commands = commands
  end

  def lint
    files = workflow_files
    if files.empty?
      puts "no workflows under #{@directory}; nothing to lint"
      return
    end

    # Passed explicitly rather than left to the linter's own discovery, so this
    # cannot pass vacuously when the directory is not where it expects.
    @commands.execute(executable, *files)
  end

  private

  def workflow_files
    Dir.glob(File.join(@directory, "*.{yml,yaml}"))
  end

  def executable
    found = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
      .map { |directory| File.join(directory, @tool) }
      .find { |candidate| File.executable?(candidate) }
    return found if found

    abort "#{@tool} is not installed, so #{@directory} cannot be linted; " \
          "install it with `brew install #{@tool}`"
  end
end

# Docker registry HTTP API, with anonymous pull access
class Registry
  # A digest has to name what `docker pull` resolves: the manifest list for a
  # multi-platform image, else the single manifest.
  MANIFEST_TYPES = [
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
  ].join(", ")

  class Error < StandardError; end

  def initialize(host: "registry-1.docker.io", token_url: "https://auth.docker.io/token",
                 service: "registry.docker.io")
    @host = host
    @token_url = token_url
    @service = service
  end

  # Every tag of a repository, following the API's pagination
  def tags(repository)
    path = "/v2/#{repository}/tags/list?n=1000"
    found = []
    while path
      response = request(Net::HTTP::Get, repository, path)
      raise Error, "listing #{repository} tags: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      found.concat(JSON.parse(response.body).fetch("tags") || [])
      path = response["link"]&.[](%r{<([^>]+)>;\s*rel="next"}, 1)
    end
    found
  end

  # The digest a tag resolves to, or nil when the tag does not exist
  def digest(repository, tag)
    response = request(Net::HTTP::Head, repository, "/v2/#{repository}/manifests/#{tag}", accept: MANIFEST_TYPES)
    return nil if response.is_a?(Net::HTTPNotFound)
    raise Error, "resolving #{repository}:#{tag}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    response["docker-content-digest"]
  end

  private

  def request(type, repository, path, accept: nil)
    Net::HTTP.start(@host, 443, use_ssl: true) do |http|
      request = type.new(path)
      request["Authorization"] = "Bearer #{token(repository)}"
      request["Accept"] = accept if accept
      http.request(request)
    end
  end

  def token(repository)
    uri = URI(@token_url)
    uri.query = URI.encode_www_form(service: @service, scope: "repository:#{repository}:pull")
    response = Net::HTTP.get_response(uri)
    raise Error, "token for #{repository}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body).fetch("token")
  end
end

# The lines of a build's files that name what is built: our version, the
# Telegraf release and its base digest in the IMAGE literal and the
# Dockerfile's ARG defaults, the version label they make, and the README's
# published tag
#
# Edits are line-anchored and must each match exactly once, so a file whose
# shape has drifted fails the edit instead of being half rewritten. It only
# ever changes those values; `rake release` uses it to change ours.
class SourceTree
  Build = Data.define(:own_version, :telegraf_version, :base_digest) do
    def version
      "#{telegraf_version}+image.#{own_version}"
    end

    def tag
      version.tr("+", "_")
    end
  end

  class Error < StandardError; end

  def initialize(directory)
    @directory = directory
  end

  def read
    rakefile = file("Rakefile")
    Build.new(own_version: value(rakefile, %r{^  own_version: "([^"]+)",$}),
              telegraf_version: value(rakefile, %r{^  telegraf_version: "([^"]+)",$}),
              base_digest: value(rakefile, %r{^  base_digest: "([^"]+)",$}))
  end

  def repository
    value(file("Rakefile"), %r{^  repository: "([^"]+)",$})
  end

  def write(build)
    published = "#{repository}:#{build.tag}"
    edit("Rakefile") do |text|
      text = replace(text, %r{^  own_version: "[^"]+",$}, %(  own_version: "#{build.own_version}",))
      text = replace(text, %r{^  telegraf_version: "[^"]+",$}, %(  telegraf_version: "#{build.telegraf_version}",))
      replace(text, %r{^  base_digest: "[^"]+",$}, %(  base_digest: "#{build.base_digest}",))
    end
    edit("Dockerfile") do |text|
      text = replace(text, %r{^ARG TELEGRAF_VERSION=.*$}, "ARG TELEGRAF_VERSION=#{build.telegraf_version}")
      text = replace(text, %r{^ARG BASE_DIGEST=.*$}, "ARG BASE_DIGEST=#{build.base_digest}")
      replace(text, %r{^ARG IMAGE_VERSION=.*$}, "ARG IMAGE_VERSION=#{build.version}")
    end
    edit("README.md") do |text|
      replace(text, %r{^Published as \*\*`[^`]+`\*\*\.$}, "Published as **`#{published}`**.")
    end
  end

  private

  def file(name)
    File.read(File.join(@directory, name))
  end

  def edit(name)
    path = File.join(@directory, name)
    File.write(path, yield(File.read(path)))
  end

  def value(text, pattern)
    matches = text.scan(pattern)
    raise Error, "expected one match of #{pattern.source} in #{@directory}, found #{matches.size}" unless matches.size == 1

    matches.first.first
  end

  def replace(text, pattern, line)
    count = text.scan(pattern).size
    raise Error, "expected one match of #{pattern.source} in #{@directory}, found #{count}" unless count == 1

    text.sub(pattern) { line }
  end
end

# Builds one version of ours — the one checked out — with every upstream
# telegraf:<version>-alpine at or above a floor, and publishes each build not
# yet on Docker Hub. Runs on a version tag of ours, `v<own>`; writes nothing to
# git. Each build is the checked-out image with another Telegraf release and
# its base digest passed in as build arguments.
#
# A build already on Docker Hub is done: upstream rebuilding its base in place
# changes nothing. Telegraf releases go oldest first, and the first failure
# stops the run, so no build lands while an older one is broken; the next run
# starts over from the same place.
class Builds
  class Error < StandardError; end

  def initialize(image:, upstream:, floor:, registry: Registry.new)
    @image = image
    @upstream = upstream
    @floor = Gem::Version.new(floor)
    @registry = registry
  end

  # Upstream releases at or above the floor, oldest first. Only exact
  # `X.Y.Z-alpine` tags: the moving `X.Y-alpine` and `alpine` tags alias these,
  # and release candidates are not releases.
  def telegraf_versions
    @registry.tags(@upstream)
      .filter_map { |tag| tag[%r{\A(\d+\.\d+\.\d+)-alpine\z}, 1] }
      .map { |text| Gem::Version.new(text) }
      .select { |version| version >= @floor }
      .sort
  end

  # The checked-out image built on one Telegraf release, for building it by
  # hand: the release must exist upstream and be at or above the floor, as the
  # release workflow would build it.
  def for_release(text)
    version = Gem::Version.new(text)
    raise Error, "Telegraf #{text} is below this version's floor, #{@floor}" if version < @floor

    for_telegraf(version)
  end

  def plan
    telegraf_versions.each do |version|
      image = for_telegraf(version, digest: false)
      puts "#{image.version}: #{published?(image) ? "published" : "to build"}"
    end
  end

  def publish_all(dry_run:)
    telegraf_versions.each do |version|
      image = for_telegraf(version)
      if published?(image)
        puts "#{image.version}: published"
        next
      end

      puts "#{image.version}: building Telegraf #{version} on #{image.base_digest}"
      image.build
      image.verify
      if dry_run
        puts "#{image.version}: dry run, so verified but not published"
        next
      end

      image.publish
    end
  end

  private

  # The checked-out image built on another Telegraf release. Without a digest,
  # for naming only — resolving one is a registry round trip per release.
  def for_telegraf(version, digest: true)
    base_digest = digest ? base_digest_for(version) : @image.base_digest
    @image.with_telegraf(telegraf_version: version.to_s, base_digest: base_digest)
  end

  def base_digest_for(version)
    digest = @registry.digest(@upstream, "#{version}-alpine")
    raise Error, "#{@upstream}:#{version}-alpine does not exist" if digest.nil?

    digest
  end

  def published?(image)
    !@registry.digest(image.repository, image.tag).nil?
  end
end

# Runs the release workflow on every version tag of ours, so each is built
# with Telegraf releases that appeared since. Writes nothing to git: the
# release workflow builds from the tag itself.
#
# Versions of ours go oldest first, each waited for, and do not hold each other
# up: a failing one is reported and the next still runs.
class Mirror
  class Error < StandardError; end

  OWN_TAG = %r{\Av(\d+\.\d+\.\d+)\z}

  def initialize(release_workflow:, commands: CommandRunner.new)
    @release_workflow = release_workflow
    @commands = commands
  end

  # The released versions of ours, oldest first: every `vX.Y.Z` tag.
  def own_versions
    (@commands.capture("git", "tag", "--list", "v*") || "")
      .lines.filter_map { |tag| tag.strip[OWN_TAG, 1] }
      .map { |text| Gem::Version.new(text) }
      .sort
  end

  def plan
    own_versions.each { |own| puts "v#{own}: release workflow" }
  end

  def dispatch_all(dry_run:)
    failed = own_versions.reject do |own|
      dispatch("v#{own}", dry_run: dry_run)
    end
    raise Error, "release runs failed for #{failed.map { "v#{it}" }.join(", ")}" unless failed.empty?
  end

  private

  # Waited for, so versions of ours do not run at the same time and a failure
  # is reported here. True when the run succeeded.
  def dispatch(tag, dry_run:)
    if dry_run
      puts "#{tag}: dry run, so the release workflow is not dispatched"
      return true
    end

    dispatched = Time.now.utc
    @commands.execute("gh", "workflow", "run", @release_workflow, "--ref", tag)
    run = dispatched_run(tag, dispatched)
    @commands.capture_merged("gh", "run", "watch", run.to_s, "--exit-status", "--interval", "30").tap do |output|
      warn "#{tag}: release run #{run} failed" if output.nil?
    end
  end

  def dispatched_run(tag, dispatched)
    60.times do
      output = @commands.capture("gh", "run", "list", "--workflow", @release_workflow, "--event", "workflow_dispatch",
                                 "--branch", tag, "--json", "databaseId,createdAt", "--limit", "10")
      run = JSON.parse(output || "[]").find { |candidate| Time.parse(candidate["createdAt"]) >= dispatched - 10 }
      return run["databaseId"] if run

      sleep 5
    end
    raise Error, "the #{@release_workflow} run for #{tag} never appeared"
  end
end

# Releases a version of ours. Run on `main` at `X.Y.0-dev`, it branches
# `X.Y.x`, commits and tags `X.Y.0` there, commits `X.Y.1-dev` after it, and
# moves `main` on to `X.(Y+1).0-dev`. Run on an `X.Y.x` branch at
# `X.Y.Z-dev`, it releases the patch `X.Y.Z` there and moves the branch on to
# `X.Y.(Z+1)-dev`.
#
# It checks everything it can before changing anything, and never pushes:
# pushing the tag is what starts the mirror, which builds the release with
# every tracked Telegraf release, so that is left to a person.
class Release
  class Error < StandardError; end

  DEVELOPMENT = %r{\A(\d+)\.(\d+)\.(\d+)-dev\z}
  LINE = %r{\A(\d+)\.(\d+)\.x\z}

  def initialize(main: "main", commands: CommandRunner.new)
    @main = main
    @commands = commands
  end

  def run
    raise Error, "commit or stash your changes first" unless capture("git", "status", "--porcelain").empty?

    branch = capture("git", "branch", "--show-current")
    version = SourceTree.new(".").read.own_version
    major, minor, patch = version.match(DEVELOPMENT)&.captures&.map { Integer(it) }
    raise Error, "#{version} is not a development version, X.Y.Z-dev" if major.nil?

    if branch == @main
      release_from_main(major, minor, patch)
    elsif (line = branch.match(LINE)) && line.captures.map { Integer(it) } == [major, minor]
      release_on_line(major, minor, patch)
    else
      raise Error, "release from #{@main}, or from the #{major}.#{minor}.x branch, not from #{branch.inspect}"
    end
  end

  private

  def release_from_main(major, minor, patch)
    raise Error, "#{@main} must be at X.Y.0-dev to branch a release, not #{major}.#{minor}.#{patch}-dev" \
      unless patch.zero?

    line = "#{major}.#{minor}.x"
    raise Error, "branch #{line} already exists" if ref?("refs/heads/#{line}") || ref?("refs/remotes/origin/#{line}")

    ensure_untagged(major, minor, patch)
    @commands.execute("git", "branch", line)
    Dir.mktmpdir("release-") do |parent|
      directory = File.join(parent, "tree")
      @commands.execute("git", "worktree", "add", "--quiet", directory, line)
      begin
        release_in(directory, major, minor, patch)
      ensure
        @commands.execute("git", "worktree", "remove", "--force", directory)
      end
    end
    advance(".", "#{major}.#{minor + 1}.0-dev")
    report(major, minor, patch, [@main, line])
  end

  def release_on_line(major, minor, patch)
    ensure_untagged(major, minor, patch)
    release_in(".", major, minor, patch)
    report(major, minor, patch, ["#{major}.#{minor}.x"])
  end

  def release_in(directory, major, minor, patch)
    version = "#{major}.#{minor}.#{patch}"
    set_version(directory, version)
    commit(directory, "chore: release #{version}")
    @commands.execute("git", "tag", "--annotate", "v#{version}", "--message", "Release #{version}", chdir: directory)
    advance(directory, "#{major}.#{minor}.#{patch + 1}-dev")
  end

  def advance(directory, version)
    set_version(directory, version)
    commit(directory, "chore: start #{version}")
  end

  def set_version(directory, version)
    tree = SourceTree.new(directory)
    tree.write(tree.read.with(own_version: version))
  end

  def commit(directory, message)
    @commands.execute("git", "commit", "--all", "--quiet", "--message", message, chdir: directory)
  end

  def ensure_untagged(major, minor, patch)
    tag = "v#{major}.#{minor}.#{patch}"
    raise Error, "tag #{tag} already exists" if ref?("refs/tags/#{tag}")
  end

  def report(major, minor, patch, branches)
    tag = "v#{major}.#{minor}.#{patch}"
    puts "Released #{major}.#{minor}.#{patch} as #{tag}. Nothing is pushed; pushing the tag starts the mirror:"
    puts "  git push --atomic origin #{branches.join(" ")} #{tag}"
  end

  def ref?(ref)
    !@commands.capture("git", "rev-parse", "--verify", "--quiet", ref).nil?
  end

  def capture(*arguments)
    output = @commands.capture(*arguments)
    raise Error, "#{arguments.join(" ")} failed" if output.nil?

    output.strip
  end
end

IMAGE = Image.new(
  repository: "jochen/telegraf",
  # This project's version. It fixes the Dockerfile, node-tool and the tooling
  # base below. `X.Y.Z-dev` between releases; `rake release` commits and tags
  # `X.Y.Z`, and the tag is what has the mirror build it with every tracked
  # Telegraf release.
  own_version: "1.0.0",
  # The Telegraf release this checkout builds, and the digest of its base: what
  # differs between the builds of one version of ours, and what the mirror
  # writes on each build's branch. Here, what CI tests a version of ours with.
  telegraf_version: "1.40.0",
  base_digest: "sha256:de158bd5b050cbb763fdc921bd01c8faf85408317176ccbcca2ca514debbaa1f",
  # The Alpine image node-tool is built on and the test host runs, the same for
  # every build of one version of ours. Its packages are not pinned: the stages
  # take what this Alpine release serves. `rake image:versions` prints the
  # current digest.
  tooling_base: "alpine:3.23.7",
  tooling_digest: "sha256:ff7f0c727dd796aa36787bfcd9a64bf35a6ce72a73451b3359fde849b6703d63",
  platforms: ["linux/amd64", "linux/arm64"].map { |text| Image::Platform.parse(text) }
).freeze

# The oldest upstream Telegraf release this version of ours is built with,
# inclusive. Older bases predate what the Dockerfile relies on; lowering this in
# a new version of ours backfills them, oldest first.
TELEGRAF_FLOOR = "1.40.0"

MIRROR = Mirror.new(release_workflow: "release.yml")

# IMAGE_PLATFORMS narrows the platforms, e.g. `IMAGE_PLATFORMS=linux/arm64`.
# IMAGE_BUILD_CACHE names a directory to keep build layers in between runs,
# which CI sets; it needs a buildx builder that exports caches.
def platform_image
  requested = ENV.fetch("IMAGE_PLATFORMS", "").split(",").map(&:strip).reject(&:empty?)
  image = requested.empty? ? IMAGE : IMAGE.with_platforms(requested.map { |text| Image::Platform.parse(text) })
  cache = ENV.fetch("IMAGE_BUILD_CACHE", "").strip
  cache.empty? ? image : image.with_build_cache(cache)
end

# The image on the Telegraf release a task was given, e.g. `rake test[1.40.3]`,
# with that release's base digest looked up on Docker Hub, as the release
# workflow does. Without one, the release pinned in IMAGE.
def selected_image(telegraf_version = nil)
  requested = telegraf_version.to_s.strip
  return platform_image if requested.empty? || requested == IMAGE.telegraf_version

  selected_builds.for_release(requested)
end

# The argument the image tasks take. Rake hands it on to prerequisites that
# declare it too, so `push` and `test` pass it to each task they run.
TELEGRAF_ARGUMENT = [:telegraf_version].freeze

namespace "image" do
  desc "Print the configuration: the build, its published tag, and the pinned bases"
  task "config", TELEGRAF_ARGUMENT do |_task, args|
    selected_image(args[:telegraf_version]).describe
  end

  desc "Print the fully qualified image reference"
  task "reference", TELEGRAF_ARGUMENT do |_task, args|
    puts selected_image(args[:telegraf_version]).reference
  end

  desc "Print this project's version, which a vX.Y.Z tag releases"
  task "own_version" do
    puts selected_image.own_version
  end

  desc "Print the git tag this build expects to be released under"
  task "release_ref" do
    puts selected_image.release_reference
  end

  desc "Build one multi-platform image and load it into the local daemon"
  task "build", TELEGRAF_ARGUMENT do |_task, args|
    selected_image(args[:telegraf_version]).build
  end

  desc "Run the verification checks against the locally built image"
  task "verify", TELEGRAF_ARGUMENT do |_task, args|
    selected_image(args[:telegraf_version]).verify
  end

  desc "Push the already-built local image, without building or verifying"
  task "publish", TELEGRAF_ARGUMENT do |_task, args|
    selected_image(args[:telegraf_version]).publish
  end

  desc "Build, verify, then push"
  task "push", TELEGRAF_ARGUMENT => %w[build verify publish]

  desc "Report the current digests of the tooling and Telegraf bases, for bumping the pins"
  task "versions" do
    selected_image.report_available_versions
  end
end

# Every tracked Telegraf release, so no task argument chooses one.
def selected_builds
  Builds.new(image: platform_image, upstream: "library/telegraf", floor: TELEGRAF_FLOOR)
end

def dry_run?
  ENV.fetch("DRY_RUN", "false") == "true"
end

namespace "builds" do
  desc "List this version's builds, one per tracked Telegraf release, and whether each is published"
  task "plan" do
    selected_builds.plan
  end

  desc "Build, verify and publish every build of this version not yet published (DRY_RUN=true skips the push)"
  task "publish" do
    selected_builds.publish_all(dry_run: dry_run?)
  end
end

namespace "mirror" do
  desc "List the version tags of ours the release workflow is run on"
  task "plan" do
    MIRROR.plan
  end

  desc "Run the release workflow on every version tag of ours (DRY_RUN=true only lists them)"
  task "sync" do
    MIRROR.dispatch_all(dry_run: dry_run?)
  end
end

desc "Release the development version: commit and tag it, and move on to the next (never pushes)"
task "release" do
  Release.new.run
end

desc "Build and verify the image"
task "test", TELEGRAF_ARGUMENT => ["image:build", "image:verify"]

namespace "lint" do
  desc "Lint the GitHub Actions workflows with actionlint"
  task "github" do
    WorkflowLinter.new.lint
  end
end

desc "Run every linter"
task "lint" => "lint:github"
