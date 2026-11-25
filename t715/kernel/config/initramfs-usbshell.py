#!/usr/bin/env python3
"""Make the kernel's initramfs: the root image work stream's initramfs plus the bring-up knob
t715.usbshell=1 (the owner's, 2026-11-24).

    python3 -I kernel-out/initramfs-usbshell.py rootfs/out/initramfs/root kernel-out/initramfs-root

Copies SRC to DST (DST is replaced) and adds to DST/init a function usb_shell, run right after
read_knobs when the kernel command line has t715.usbshell=1: an ECM gadget through configfs at
172.16.42.1/24 (the owner's 32-bit USB network), udhcpd for the Mac (172.16.42.2-20) and telnetd
with a root shell on 172.16.42.1:23, before anything can fail; the address stays on the interface
after switch_root, so the image's sshd answers on it even if the image's own USB service does not
come up. Bring-up only: the link is a cable to the owner's Mac, and telnet has no password.
"""
import shutil
import sys
from pathlib import Path

FN = r'''# usb_shell: t715.usbshell=1, bring-up only (added by kernel-out/initramfs-usbshell.py). An ECM
# gadget through configfs, 172.16.42.1/24, a DHCP server for the Mac (172.16.42.2-20) and telnetd
# with a root shell on 172.16.42.1:23, made before anything can fail. The address stays on the
# interface after switch_root, so the image's sshd answers on it even if the image's own USB
# service does not come up. The link is a cable to the owner's Mac; no password.
usb_shell() {
    [ "$USBSHELL" = 1 ] || return 0
    mkdir -p /sys/kernel/config
    is_mounted /sys/kernel/config || mount -t configfs none /sys/kernel/config 2>/dev/null || true
    g=/sys/kernel/config/usb_gadget/g1
    if ! mkdir -p "$g" 2>/dev/null; then warn "usbshell: no configfs gadget"; return 0; fi
    echo 0x05ac > "$g/idVendor"; echo 0x0a14 > "$g/idProduct"
    echo 0x0100 > "$g/bcdDevice"; echo 0x0200 > "$g/bcdUSB"
    mkdir -p "$g/strings/0x409"
    echo 0123456789ABCDEF > "$g/strings/0x409/serialnumber"
    echo Samsung > "$g/strings/0x409/manufacturer"
    echo "SM-T715 arm64 initramfs" > "$g/strings/0x409/product"
    mkdir -p "$g/functions/ecm.0" "$g/configs/b.1/strings/0x409"
    echo ECM > "$g/configs/b.1/strings/0x409/configuration"
    [ -e "$g/configs/b.1/ecm.0" ] || ln -s "$g/functions/ecm.0" "$g/configs/b.1/ecm.0"
    n=0; udc=
    while [ $n -lt 30 ]; do udc=$(ls /sys/class/udc 2>/dev/null | head -n1); [ -n "$udc" ] && break; sleep 1; n=$((n + 1)); done
    if [ -z "$udc" ]; then warn "usbshell: no USB device controller after 30 s"; return 0; fi
    echo "$udc" > "$g/UDC" || { warn "usbshell: the gadget did not bind to $udc"; return 0; }
    ifn=$(cat "$g/functions/ecm.0/ifname" 2>/dev/null); [ -n "$ifn" ] || ifn=usb0
    ip link set "$ifn" up; ip addr add 172.16.42.1/24 dev "$ifn" 2>/dev/null || true
    printf 'start 172.16.42.2\nend 172.16.42.20\ninterface %s\nlease_file /run/udhcpd.leases\nopt subnet 255.255.255.0\nopt lease 864000\n' "$ifn" > /run/udhcpd.conf
    : > /run/udhcpd.leases
    udhcpd /run/udhcpd.conf 2>/dev/null || warn "usbshell: udhcpd did not start"
    telnetd -l /bin/sh -b 172.16.42.1 -p 23 2>/dev/null || warn "usbshell: telnetd did not start"
    log "usbshell: gadget on $udc, $ifn at 172.16.42.1, telnet 23 (bring-up)"
}

'''


def edit(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        sys.exit(f"initramfs-usbshell: the anchor {old!r} is not in init exactly once")
    return text.replace(old, new)


def main() -> int:
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    if not (src / "init").is_file():
        sys.exit(f"initramfs-usbshell: no init in {src}")
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst, symlinks=True)
    init = dst / "init"
    s = init.read_text()
    s = edit(s, "WDTFEED=0\n", "WDTFEED=0\nUSBSHELL=0\n")
    s = edit(s, "            t715.wdtfeed=1) WDTFEED=1 ;;\n",
             "            t715.wdtfeed=1) WDTFEED=1 ;;\n            t715.usbshell=1) USBSHELL=1 ;;\n")
    s = edit(s, "main() {\n", FN + "main() {\n")
    if "mkdir -p /proc /sys /dev /run" not in s:
        s = edit(s, "mount_early() {\n", "mount_early() {\n    mkdir -p /proc /sys /dev /run 2>/dev/null || true   # the archive has no /sys\n")
    s = edit(s, "    read_knobs\n    wdt_feed_start\n", "    read_knobs\n    usb_shell\n    wdt_feed_start\n")
    init.write_text(s)
    print(f"{dst}: initramfs of {src} with t715.usbshell")
    return 0


if __name__ == "__main__":
    sys.exit(main())
