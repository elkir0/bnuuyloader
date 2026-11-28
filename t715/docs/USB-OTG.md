# USB host (OTG) on the SM-T715 (arm64)

State of 2026-11-28. On the 64-bit kernel the micro-USB port of the SM-T715 was device only: the
USB cable's network link, nothing else. Since 2026-11-28 a micro-USB OTG adapter makes the port a
host. Three patches, `t715/kernel/patches/0013` to `0015`, give a plugged device its three needs:
data lines routed to the controller, 5 V on VBUS, and the dual-role controller in host mode. The
32-bit port is unchanged: its board file keeps the port a device only. This note says what each
piece does and why it was needed, the register sequence, the configuration, what was seen on the
reference tablet on 2026-11-28, and the limits.

## 1. The three pieces, and why each was needed

An OTG host needs three things at once: the data lines routed to the controller, 5 V on VBUS, and
the controller itself in host mode. On this board the first two belong to the SM5703, which is
both the MUIC (the cable detection, on I2C) and the charger (the 5 V boost), and the third to the
dwc3 dual-role controller. Each was missing on the 64-bit kernel, and each patch supplies one.

- **The MUIC's VBUS switch (patch `0013`, extcon: sm5502).** The mainline MUIC driver
  (`extcon-sm5502`, compatible `siliconmitus,sm5703-muic`) routes D+/D- to USB for an OTG cable
  but left the VBUSIN switch open. On the SM5703 the charger's 5 V boost comes out on VBUSOUT and
  reaches the connector only through that switch, so the plugged device never got power. Samsung's
  own SM5703 MUIC driver writes MANUAL_SW1 (0x13) = 0x25 for an OTG cable: D+/D- to USB and
  VBUSIN to VBUSOUT. The patch does the same. A detach opens both switches, as before.
- **The charger's boost (patch `0014`, power: supply: sm5703).** When the MUIC reports
  `EXTCON_USB_HOST`, the charger driver puts the chip in USB OTG mode, in Samsung's sequence
  (section 2), and puts it back to charging when the cable is gone. While the boost runs, the
  chip's own 5 V makes VBUSOK read 1, so the input is treated as absent: no cable, offline, no
  input forcing, no recharge. STATUS1 (0x08) bit 7, OTGFAIL, turns the boost off until the cable
  is plugged again. Shutdown and remove turn the boost off first. The driver never reads INT1-4
  (0x00-0x03) nor writes INTMSK1-4 (0x04-0x07). The registers and the sequence come from Samsung's
  downstream driver for this chip (an MSM8916 Samsung kernel carries the same chip and driver).
  The decisions are made in the charger's periodic work, under its lock; the extcon notifier only
  schedules that work.
- **The controller's role (patch `0015`, arm64: dts: exynos: gts28ltexx).** A 64-bit-only dtsi,
  `exynos5433-gts28ltexx-otg.dtsi`, sets `dr_mode = "otg"` and `extcon = <&muic>` on dwc3: an OTG
  adapter (`EXTCON_USB_HOST`) makes the DRD controller a host through xHCI, anything else a
  device. The 32-bit board file keeps the port a device only. Stock (Android) ran it in dual role
  too.

## 2. The register sequence

The enable order is Samsung's: OTGCURRENTCNTL first, then FLEDCNTL6, then CNTL. The disable order
is the reverse in effect: BSTOUT back to 4.5 V, CNTL mode back to 5, and the periodic work then
choosing between modes 4 and 5 as before.

| Chip | Register | OTG cable plugged | Cable removed |
|---|---|---|---|
| MUIC | MANUAL_SW1 (0x13) | 0x25: D+/D- to USB, VBUSIN to VBUSOUT | both switches open |
| charger | OTGCURRENTCNTL (0x60), bits 1:0 | 3: 1200 mA (0/1/2 are 500/700/900 mA) | unchanged |
| charger | FLEDCNTL6 (0x19), BSTOUT bits 3:0 | 0x0A: 5.0 V | 0x05: 4.5 V |
| charger | CNTL (0x0C), mode | 7 | 5 |
| charger | STATUS1 (0x08), bit 7 | OTGFAIL: the boost goes off and stays off while the cable stays | the latch is cleared: the next plug tries again |

## 3. The configuration

All of it is in `t715/kernel/config/config-arm64.local`, added on 2026-11-28 on top of the release
configuration:

- `CONFIG_USB_DWC3_DUAL_ROLE=y`, and `CONFIG_USB_DWC3_GADGET=n` (a choice: dual role ends gadget);
- `CONFIG_USB_XHCI_HCD=y`, `CONFIG_USB_XHCI_PLATFORM=y`;
- `CONFIG_SCSI=y`, built in (the release builds `SCSI_MOD` y);
- as modules: SCSI disks (`CONFIG_BLK_DEV_SD`), usb-storage, UAS, NTFS3, HID multitouch, Logitech
  (DJ, HID++) and Apple HID, usbnet with CDC Ethernet, CDC NCM and RNDIS host, AX88179 and
  RTL8152, USB audio, CDC ACM, USB serial (FTDI, CP210x, CH341, PL2303), UVC webcams.

`t715/build-arm64.sh`'s configuration check now accepts a symbol the 32-bit release builds and
our own lines change on purpose (`CONFIG_X=n` included): `CONFIG_USB_DWC3_GADGET`, which
`CONFIG_USB_DWC3_DUAL_ROLE` ends.

## 4. Seen on the reference tablet, 2026-11-28

Kernel built from these sources. The role follows the cable without anything being restarted: dwc3
starts as a device at boot, becomes a host when the MUIC reports `EXTCON_USB_HOST`, and binds the
gadget again by itself when the cable goes back to device.

- **At boot dwc3 starts as a device**: the USB cable's network link works as before.
- **Forced to host through debugfs, with the computer's cable in**: xHCI comes up with a USB 2.0
  root hub (480 Mbit/s) and a USB 3.0 one, one port each. Back to device, the USB gadget binds
  again by itself and the network link returns; nothing was restarted.
- **With an OTG adapter and a 2 GB USB flash disk**: the MUIC reports USB-HOST, dwc3 becomes a
  host, and the charger reads CNTL 0x57, BSTOUT 0x0a, OTGCURRENT 3, no OTGFAIL. The disk
  enumerates at high speed as usb-storage (sda, one FAT partition), and the image's udiskie
  mounts it under `/run/media`. Adapter removed: the boost is off (CNTL 0x55, BSTOUT 0x05), dwc3
  is a device again. The computer's cable plugged back: charging and the network link return.

## 5. Limits, and what is not tried yet

- The micro-USB port is USB 2.0: no SuperSpeed device runs faster than 480 Mbit/s, whatever the
  xHCI root hubs report.
- The boost's OTG current limit is 1200 mA (OTGCURRENTCNTL bits 1:0 = 3); what a plugged device
  actually draws against that limit has not been measured.
- Not tried yet: keyboards, mice, hubs, Ethernet adapters, USB audio; charging while a device is
  plugged in (a Y cable or a powered hub); sleep with a device plugged in; a clean eject.

## 6. How to turn it off

Drop the include of `exynos5433-gts28ltexx-otg.dtsi` from the arm64 board DTS: dwc3 is then a device
only again, whatever the cable. The MUIC still reports an OTG adapter as `EXTCON_USB_HOST`, and the
charger, which listens to the MUIC directly, still turns its boost on for it: a plugged device gets
5 V, and nothing talks to it. To keep VBUS off as well, leave `0014` out too. With `0013` alone the
MUIC closes its VBUS switch for an OTG cable, but no boost runs behind it.
