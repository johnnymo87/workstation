# COPY of eternal-machinery nix/history_shell_seccomp.py (qpmfc.101.3). That repo is
# private, so this repo cannot import it. The two copies MUST stay in step: the policy
# is the sandbox's syscall filter, and the EM escape suite compares the sha256 that
# the server's ping reports (seccomp_sha256) with the blob EM's own generator makes.
# Change both together, byte for byte below this header. Built by default.nix.
"""Write the history shell's seccomp program (qpmfc.101.3). Run by nix/history-shell.nix.

    python3 history_shell_seccomp.py OUT.bpf

The policy is the `DENY`, `DENY_BY_NUMBER`, `DENY_NOSYS`, `CLONE_NEW` and `SOCKET_CALLS` tables below. It is an
allow-by-default filter with deny rules, because a blanket syscall allow list breaks
Python and bash in ways only a long soak finds. A syscall name the architecture does not
know is an error (the build fails) so a typo cannot silently drop a rule.
"""

import errno
import sys

import seccomp


AF_UNIX = 1

#: Refused with EPERM for any caller.
DENY = (
    # the kernel's large attack surfaces
    "io_uring_setup",
    "io_uring_enter",
    "io_uring_register",
    "bpf",
    "perf_event_open",
    "userfaultfd",
    # keyrings
    "keyctl",
    "add_key",
    "request_key",
    # reading or steering other processes
    "ptrace",
    "process_vm_readv",
    "process_vm_writev",
    # namespaces, mounts and roots
    "unshare",
    "setns",
    "mount",
    "umount2",
    "pivot_root",
    "open_by_handle_at",
    "name_to_handle_at",
    # the new mount API (a mount without mount(2))
    "fsopen",
    "fsconfig",
    "fsmount",
    "fspick",
    "move_mount",
    "open_tree",
    "mount_setattr",
    # reaching into other processes' descriptors and memory
    "pidfd_getfd",
    "process_madvise",
    # loading code into the kernel
    "kexec_load",
    "kexec_file_load",
    "init_module",
    "finit_module",
    "delete_module",
)

#: Refused with EPERM, by number, for syscalls newer than libseccomp's name table
#: (2.6.0 has no open_tree_attr). 467 on x86_64 and aarch64 alike.
DENY_BY_NUMBER = {"open_tree_attr": 467}

#: Refused with ENOSYS so a libc falls back to the older call the filter can read.
DENY_NOSYS = ("clone3",)

#: `clone` with any of these flags is refused with EPERM.
CLONE_NEW = {
    "CLONE_NEWNS": 0x00020000,
    "CLONE_NEWCGROUP": 0x02000000,
    "CLONE_NEWUTS": 0x04000000,
    "CLONE_NEWIPC": 0x08000000,
    "CLONE_NEWUSER": 0x10000000,
    "CLONE_NEWPID": 0x20000000,
    "CLONE_NEWNET": 0x40000000,
}

#: Only these socket families may be created.
SOCKET_CALLS = ("socket", "socketpair")


def build() -> "seccomp.SyscallFilter":
    f = seccomp.SyscallFilter(defaction=seccomp.ALLOW)
    for name in DENY:
        f.add_rule(seccomp.ERRNO(errno.EPERM), name)
    for number in DENY_BY_NUMBER.values():
        f.add_rule(seccomp.ERRNO(errno.EPERM), number)
    for name in DENY_NOSYS:
        f.add_rule(seccomp.ERRNO(errno.ENOSYS), name)
    for name in SOCKET_CALLS:
        f.add_rule(
            seccomp.ERRNO(errno.EPERM), name, seccomp.Arg(0, seccomp.NE, AF_UNIX)
        )
    for bit in CLONE_NEW.values():
        f.add_rule(
            seccomp.ERRNO(errno.EPERM),
            "clone",
            seccomp.Arg(0, seccomp.MASKED_EQ, bit, bit),
        )
    return f


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: history_shell_seccomp.py OUT.bpf", file=sys.stderr)
        return 2
    f = build()
    with open(argv[1], "wb") as out:
        f.export_bpf(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
