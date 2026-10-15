//! Runs the node's own `pvs`, `vgs`, `lvs`, `smartctl` or `zpool` for
//! Telegraf, with the capabilities that tool needs, and refuses everything
//! else.
//!
//! The image ships none of LVM, smartmontools and ZFS. This wrapper enters the
//! node's mount namespace and runs the node's own tools there, so the node's
//! versions and configuration apply — no skew between image and node. It
//! reaches that namespace through the node's `/proc`, which the consumer
//! already mounts at `/hostfs/proc` for Telegraf's process metrics. The kernel
//! guards `/hostfs/proc/1/ns/mnt` with a ptrace check, and Telegraf has no
//! `cap_sys_ptrace`, so Telegraf itself cannot open it.
//!
//! The tools are powerful: `lvm` is the whole LVM suite in one binary,
//! `smartctl` can start self-tests and change device settings, and `zpool` can
//! destroy pools. So each runs only with the options Telegraf passes, matched
//! exactly, and with the capabilities its reporting needs, never the union.
//!
//! All capabilities are permitted-only on this file. The two used to enter the
//! node are effective for opening the namespace and the `setns` call, then
//! removed from every set; the tool's own take effect as ambient capabilities
//! from its exec on, with an environment this program sets.

use std::env;
use std::ffi::{OsStr, OsString, c_int, c_ulong};
use std::fs::{self, File};
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, exit};

const CAP_DAC_OVERRIDE: u32 = 1;
const CAP_FOWNER: u32 = 3;
const CAP_SYS_RAWIO: u32 = 17;
const CAP_SYS_CHROOT: u32 = 18;
const CAP_SYS_PTRACE: u32 = 19;
const CAP_SYS_ADMIN: u32 = 21;

/// Needed only to enter the node: the kernel guards the namespace link with a
/// ptrace check, and `setns` into a mount namespace takes `cap_sys_chroot` as
/// well as `cap_sys_admin`.
const ENTRY_CAPABILITIES: [u32; 2] = [CAP_SYS_CHROOT, CAP_SYS_PTRACE];

/// The node's init's mount namespace, in the node's `/proc` as the consumer
/// mounts it. Entering the namespace rather than chrooting is what gives the
/// tool the node's mount table too, which LVM reads to find sysfs.
const NODE_PROC: &str = "/hostfs/proc";
const NODE_MOUNT_NAMESPACE: &str = "/hostfs/proc/1/ns/mnt";
const CLONE_NEWNS: c_int = 0x0002_0000;
const CLONE_FS: c_int = 0x0000_0200;

/// What a value following an option may be. Every kind is a plain word, never
/// a path or anything starting with `-`.
#[derive(Clone, Copy)]
enum Value {
    /// LVM's `--reportformat`.
    ReportFormat,
    /// LVM's `--units`: letters only.
    Units,
    /// LVM's `-o`: column names separated by commas.
    Columns,
    /// smartctl's `-n` and `--nocheck`: a power mode.
    PowerMode,
    /// smartctl's `-d` and `--device`: a device type such as `sat`,
    /// `megaraid,1` or `sat+megaraid,0`.
    DeviceType,
}

impl Value {
    fn accepts(self, value: &OsStr) -> bool {
        let bytes = value.as_bytes();
        let all =
            |allowed: fn(u8) -> bool| !bytes.is_empty() && bytes.iter().all(|&byte| allowed(byte));
        match self {
            Value::ReportFormat => [&b"json"[..], b"json_std", b"basic"].contains(&bytes),
            Value::Units => all(|byte| byte.is_ascii_alphabetic()),
            Value::Columns => all(|byte| {
                byte.is_ascii_lowercase() || byte.is_ascii_digit() || b"_,".contains(&byte)
            }),
            Value::PowerMode => [&b"never"[..], b"sleep", b"standby", b"idle"].contains(&bytes),
            Value::DeviceType => {
                bytes.first().is_some_and(u8::is_ascii_alphanumeric)
                    && all(|byte| byte.is_ascii_alphanumeric() || b",+_".contains(&byte))
            }
        }
    }
}

/// One node tool: the capabilities it runs with, and exactly what Telegraf's
/// plugins pass it.
struct Tool {
    name: &'static str,
    capabilities: &'static [u32],
    /// Options taken alone.
    flags: &'static [&'static str],
    /// Options followed by a value, as a separate argument.
    valued: &'static [(&'static str, Value)],
    /// Options with the value attached, as `--option=value`.
    attached: &'static [(&'static str, Value)],
    /// Subcommands, as plain words, such as `zpool list`.
    words: &'static [&'static str],
    /// Whether device paths under `/dev/` may be given.
    devices: bool,
}

const LVM_REPORT: Tool = Tool {
    name: "",
    // cap_dac_override for /dev/mapper/control, which LVM opens read-write
    // even to report; cap_fowner because it opens devices O_NOATIME;
    // cap_sys_admin for the device-mapper ioctls that report activation.
    capabilities: &[CAP_DAC_OVERRIDE, CAP_FOWNER, CAP_SYS_ADMIN],
    flags: &["--nosuffix", "--noheadings", "--version"],
    valued: &[
        ("--reportformat", Value::ReportFormat),
        ("--units", Value::Units),
        ("-o", Value::Columns),
        ("--options", Value::Columns),
    ],
    attached: &[],
    words: &[],
    devices: false,
};

const TOOLS: [Tool; 5] = [
    Tool {
        name: "pvs",
        ..LVM_REPORT
    },
    Tool {
        name: "vgs",
        ..LVM_REPORT
    },
    Tool {
        name: "lvs",
        ..LVM_REPORT
    },
    Tool {
        name: "smartctl",
        // cap_dac_override for the root:disk device nodes; cap_sys_rawio for
        // SG_IO and ATA passthrough; cap_sys_admin for NVMe Get Log Page.
        capabilities: &[CAP_DAC_OVERRIDE, CAP_SYS_RAWIO, CAP_SYS_ADMIN],
        // What inputs.smartctl and inputs.smart pass. Nothing that tests,
        // sets or loads anything: no -t, -s, -X or --drivedb.
        flags: &[
            "--json",
            "--all",
            "--scan",
            "--scan-open",
            "--info",
            "--health",
            "--attributes",
            "--version",
            "--format=brief",
            "--tolerance=verypermissive",
            "--device=nvme",
        ],
        valued: &[
            ("--device", Value::DeviceType),
            ("-d", Value::DeviceType),
            ("-n", Value::PowerMode),
        ],
        attached: &[("--nocheck=", Value::PowerMode)],
        words: &[],
        devices: true,
    },
    Tool {
        name: "zpool",
        // cap_dac_override to open /dev/zfs, which libzfs opens read-write
        // even to list, and which a node can keep root-only 0600: measured on
        // a CI runner with the ZFS module loaded, where zpool otherwise fails
        // with "the ZFS utilities must be run as root". Listing itself needs
        // no privilege beyond that open.
        capabilities: &[CAP_DAC_OVERRIDE],
        // What examples/zfs.conf runs for pool health, `zpool list -H -p -o
        // <columns>`, and `zpool version` for verification. Nothing that
        // imports, exports, scrubs, changes or destroys a pool.
        flags: &["-H", "-p", "-Hp"],
        valued: &[("-o", Value::Columns)],
        attached: &[],
        words: &["list", "version"],
        devices: false,
    },
];

const CAPABILITY_VERSION_3: u32 = 0x2008_0522;
const PR_CAP_AMBIENT: c_int = 47;
const PR_CAP_AMBIENT_RAISE: c_ulong = 2;

#[repr(C)]
struct CapabilityHeader {
    version: u32,
    pid: c_int,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct CapabilityData {
    effective: u32,
    permitted: u32,
    inheritable: u32,
}

unsafe extern "C" {
    fn setns(fd: c_int, nstype: c_int) -> c_int;
    fn unshare(flags: c_int) -> c_int;
    fn capget(header: *mut CapabilityHeader, data: *mut CapabilityData) -> c_int;
    fn capset(header: *mut CapabilityHeader, data: *const CapabilityData) -> c_int;
    fn prctl(option: c_int, ...) -> c_int;
}

fn refuse(name: &str, message: &str) -> ! {
    eprintln!("{name}: {message}");
    exit(126)
}

fn fail(name: &str, call: &str) -> ! {
    refuse(
        name,
        &format!("{call} failed: {}", io::Error::last_os_error()),
    )
}

/// A device path: under `/dev/`, and with no `..` component to climb out.
fn is_device(argument: &OsStr) -> bool {
    let bytes = argument.as_bytes();
    bytes.starts_with(b"/dev/")
        && bytes.len() > 5
        && !bytes.split(|&byte| byte == b'/').any(|part| part == b"..")
}

fn check_arguments(tool: &Tool, arguments: &[OsString]) {
    let name = tool.name;
    let mut remaining = arguments.iter();
    while let Some(argument) = remaining.next() {
        if tool.flags.iter().any(|flag| argument == OsStr::new(flag)) {
            continue;
        }
        if let Some((_, kind)) = tool
            .valued
            .iter()
            .find(|(option, _)| argument == OsStr::new(option))
        {
            match remaining.next() {
                Some(value) if kind.accepts(value) => continue,
                _ => refuse(
                    name,
                    &format!("{} needs an allowed value", argument.to_string_lossy()),
                ),
            }
        }
        if let Some((option, kind)) = tool
            .attached
            .iter()
            .find(|(option, _)| argument.as_bytes().starts_with(option.as_bytes()))
        {
            if kind.accepts(OsStr::from_bytes(&argument.as_bytes()[option.len()..])) {
                continue;
            }
            refuse(
                name,
                &format!("{} needs an allowed value", argument.to_string_lossy()),
            );
        }
        if tool.devices && is_device(argument) {
            continue;
        }
        if tool.words.iter().any(|word| argument == OsStr::new(word)) {
            continue;
        }
        refuse(
            name,
            &format!("argument not allowed: {}", argument.to_string_lossy()),
        );
    }
}

/// Changes this process's capability sets: reads them, lets `change` edit
/// them, and writes them back.
fn update_capabilities(name: &str, change: impl FnOnce(&mut [CapabilityData; 2])) {
    let mut header = CapabilityHeader {
        version: CAPABILITY_VERSION_3,
        pid: 0,
    };
    let mut data = [CapabilityData::default(); 2];
    // SAFETY: the header and a two-element data array are what the version 3
    // interface reads and writes.
    if unsafe { capget(&mut header, data.as_mut_ptr()) } != 0 {
        fail(name, "capget");
    }
    change(&mut data);
    // SAFETY: as above.
    if unsafe { capset(&mut header, data.as_ptr()) } != 0 {
        fail(name, "capset");
    }
}

fn bit(capability: u32) -> (usize, u32) {
    ((capability / 32) as usize, 1 << (capability % 32))
}

fn identity(path: &str) -> Option<(u64, u64)> {
    fs::metadata(path)
        .ok()
        .map(|metadata| (metadata.dev(), metadata.ino()))
}

/// Moves into the node's mount namespace. The entry capabilities are effective
/// only for opening the namespace and the `setns` call, then removed from
/// every set; `cap_sys_admin`, which `setns` needs too, is no longer effective
/// afterwards. None of the file's capabilities reach the tool except its own.
fn enter_node(tool: &Tool) {
    let name = tool.name;
    if fs::symlink_metadata(NODE_MOUNT_NAMESPACE).is_err() {
        refuse(name, &format!("mount the node's /proc at {NODE_PROC}"));
    }

    update_capabilities(name, |data| {
        for capability in ENTRY_CAPABILITIES.into_iter().chain([CAP_SYS_ADMIN]) {
            let (index, mask) = bit(capability);
            data[index].effective |= mask;
        }
    });

    // Opened privileged: without the ptrace check passing, the kernel does not
    // follow the link and this resolves to the directory instead.
    let namespace = File::open(NODE_MOUNT_NAMESPACE).unwrap_or_else(|error| {
        refuse(
            name,
            &format!("opening {NODE_MOUNT_NAMESPACE} failed: {error}"),
        )
    });
    let opened = namespace.metadata().unwrap_or_else(|error| {
        refuse(
            name,
            &format!("reading {NODE_MOUNT_NAMESPACE} failed: {error}"),
        )
    });
    if opened.is_dir() {
        refuse(name, &format!("{NODE_MOUNT_NAMESPACE} is not a namespace"));
    }
    // Our own namespace means the /proc mounted is not the node's, and the
    // tool found there would be this wrapper.
    if Some((opened.dev(), opened.ino())) == identity("/proc/self/ns/mnt") {
        refuse(
            name,
            &format!("{NODE_MOUNT_NAMESPACE} is this container's own namespace, not the node's"),
        );
    }
    // The kernel lets only a process whose filesystem context no other thread
    // shares change its mount namespace, and refuses with EINVAL otherwise.
    // This program has one thread, but under QEMU's user-mode emulation, as
    // CI runs the other platform, the emulator adds threads of its own that
    // share it. A private copy is harmless where nothing shares it, and needs
    // no privilege.
    // SAFETY: no pointers; affects only this thread's filesystem context.
    if unsafe { unshare(CLONE_FS) } != 0 {
        fail(name, "taking a private filesystem context");
    }
    // SAFETY: a valid descriptor for a mount namespace, open for the call.
    if unsafe { setns(namespace.as_raw_fd(), CLONE_NEWNS) } != 0 {
        fail(name, "entering the node's mount namespace");
    }
    drop(namespace);

    update_capabilities(name, |data| {
        for capability in [
            CAP_DAC_OVERRIDE,
            CAP_FOWNER,
            CAP_SYS_RAWIO,
            CAP_SYS_CHROOT,
            CAP_SYS_PTRACE,
            CAP_SYS_ADMIN,
        ] {
            let (index, mask) = bit(capability);
            data[index].effective &= !mask;
            if !tool.capabilities.contains(&capability) {
                data[index].permitted &= !mask;
                data[index].inheritable &= !mask;
            }
        }
    });
}

/// Ambient capabilities need each one in the inheritable set first, which a
/// process may raise within its permitted set without any further privilege.
fn raise_ambient(tool: &Tool) {
    update_capabilities(tool.name, |data| {
        for &capability in tool.capabilities {
            let (index, mask) = bit(capability);
            data[index].inheritable |= mask;
        }
    });
    for &capability in tool.capabilities {
        // SAFETY: PR_CAP_AMBIENT takes four unsigned long arguments.
        let result = unsafe {
            prctl(
                PR_CAP_AMBIENT,
                PR_CAP_AMBIENT_RAISE,
                c_ulong::from(capability),
                0 as c_ulong,
                0 as c_ulong,
            )
        };
        if result != 0 {
            fail(tool.name, &format!("raising capability {capability}"));
        }
    }
}

fn main() {
    let mut arguments = env::args_os();
    let program = arguments.next().unwrap_or_default();
    let called = Path::new(&program)
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned();
    let Some(tool) = TOOLS.iter().find(|tool| tool.name == called) else {
        refuse(
            &called,
            "only pvs, vgs, lvs, smartctl and zpool are allowed",
        );
    };
    let name = tool.name;
    let arguments: Vec<OsString> = arguments.collect();
    check_arguments(tool, &arguments);
    enter_node(tool);
    raise_ambient(tool);

    let program = ["/usr/sbin", "/sbin", "/usr/bin", "/bin"]
        .iter()
        .map(|directory| format!("{directory}/{name}"))
        .find(|path| Path::new(path).exists())
        .unwrap_or_else(|| refuse(name, &format!("the node has no {name}")));
    // A second guard against running ourselves, by device and inode, as
    // paths differ between the namespaces.
    if identity(&program) == identity("/proc/self/exe") {
        refuse(
            name,
            &format!("{program} is this wrapper, not the node's {name}"),
        );
    }

    // The environment is replaced rather than passed on: the tool carries no
    // file capabilities, so nothing would protect it from LD_PRELOAD and the
    // like.
    let error = Command::new(&program)
        .arg0(name)
        .args(&arguments)
        .env_clear()
        .env("PATH", "/usr/sbin:/usr/bin:/sbin:/bin")
        .env("LC_ALL", "C")
        .exec();
    refuse(name, &format!("exec of {program} failed: {error}"));
}
