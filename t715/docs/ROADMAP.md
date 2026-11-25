# Roadmap of the arm64 Omarchy for the SM-T715

Updated 2026-11-25 (first written 2026-11-24), at the owner's request: the move to Omarchy 4.5.
The arm64 system replaces the 32-bit one (owner's decision, 2026-11-24). The 32-bit project,
`omarchy-tab-s2`, has its own roadmap, `omarchy-tab-s2/docs/ROADMAP.md`.

Legend: **done** (proven on the tablet), **built** (works on the Mac, not run on the tablet),
**open**.

## Milestone 0: a 64-bit boot of our own (done, 2026-11-23/24)

- Forged boot logo in PARAM → ARM32 code in S-Boot → `SMC 0x82000400` → AArch64 at EL2 → EL1.
- Linux 6.12.114 arm64 started by the loader; MCT as the time base (the ARM counter does not run).
- All eight cores in 64 bits through our own enable-method (`samsung,exynos5433-el2`, no PSCI).
- The production loader in PARAM starts a kernel from a slot of CACHE (two slots, hashed headers),
  and gives the tablet back to the 32-bit system by itself after a failed attempt.
- cpufreq on this chip's own tables with their rails, and the cooling maps (stage 1: A57 at 1.2 GHz
  at most). Trips as the owner chose: those of the 32-bit daily (81/95/100 °C, 81/86 °C).

## Milestone 1: the full kernel and a root image (done, 2026-11-25)

- Full kernel: the release configuration translated to arm64 (1371 options, 71 modules), the
  eight-core method, stage 1, the initramfs built in. **done**.
- Loader: one PARAM for any valid slot (stage 2 checks the record of the slot the ARM32 code chose);
  the FNV-1a carry bug of the ARM32 hash fixed; the ledger over the two boots before (`kboot6`).
  **done** (27/27 rehearsed cases; on the tablet since 2026-11-25).
- First boot of the full kernel on the tablet with a root image. **done** (2026-11-25, after the
  initramfs archive got its `/sys`).

## Milestone 2: Omarchy 4.5 on arm64 (done, 2026-11-25)

- Root image on Omarchy 4.5.0-3 with omarchy-mobile (`pkgs.omamobile.org`, the packages of the
  Lenovomarchy port) and the T715 parts (touch, keys, rotation, USB network, Wi-Fi and Bluetooth
  addresses, watchdog keeper, boot mark). **done** (the Omarchy Mobile desktop on the panel, SDDM
  autologin, Hyprland on exynos-drm).
- Display, touch, GPU (panfrost), Wi-Fi, Bluetooth, sound, sensors, battery and charger, microSD on
  arm64: **done as far as the health check sees** (drivers bound, devices present, Wi-Fi associated
  and online). Not yet used by a hand: touch gestures, rotation, sound out, Bluetooth pairing, camera.

## Milestone 3: daily use

- The arm64 system's "up" mark and watchdog keeper in the field: **done** (two daily reboots,
  2026-11-25: back in 32 s, user space in 13 s). Cold boot by the power key with the loader in
  PARAM: **done** (the owner, 2026-11-25: arm64, user space in 12 s, marked up). A soak of several
  hours: **done** (2026-11-25, three hours: twelve 3-min phases of eight busy cores, atlas peak
  94 °C, cooling to 0.9/1.0 GHz, no reboot, keeper and Wi-Fi in every sample).
- The boot screen: **done** (2026-11-25). The panel stayed black until the session (16.9 s): with
  arm64's OF_IOMMU, DECON and the other System MMU masters waited for a driver that is not built until
  the deferred-probe timeout. The System MMUs are disabled in the board tree (../kernel/patches/0008):
  DECON binds at 0.5 s; `quiet splash` give the Omarchy Plymouth splash from 4.7 to 8.6 s (Plymouth's
  framebuffer seen on the CRTC); `quiet` is console loglevel 4, so the level-3 boot mark still reaches
  the loader's ring. Left: about 4 s of text before the splash (the initramfs's own lines and two
  error lines): an initramfs `t715.quiet` as on 32-bit, at the next kernel build (loglevel 4, not 3,
  for the mark). **open**.
- `t715-keys` crashed at every screen-off (Power or two minutes idle), so the screen never went off:
  a lone `%d` in its unit, expanded by systemd. **done** (2026-11-25, `%%d`; the smoke check now
  rejects a lone `%d` in the t715 units).
- The LTE modem, the CP up: **done** (2026-11-25). S0 the CPIF bus gates as on 32-bit (G1+ go); S1
  `sec_modem_v1` built for arm64 (../kernel/patches/0009), host vectors 76/76; S2 `t715-modem` for
  aarch64 (../rootfs/pkg/t715-modem: the loader built and its whole suite run in `check()`); S3 every
  rung of the loader's ladder on the tablet, then ONLINE in 9.9 s, at every boot after `KBOOT: up`;
  innocuity hashes unchanged. `shannond`'s ModemManager facade answers; NetworkManager sees the modem.
- The LTE modem with a SIM: registration, mobile data (`t715-mobile`), SMS, calls with audio:
  **open**, needs the owner's SIM (none is in the tablet: the 32-bit system saw "absent" too).
- The modem in the shell: **done** (2026-11-25). omamobile-shell 0.2.133-4.1: the Mobile data tile
  (NetworkManager's `t715-mobile`, signal and technology from `shannonctl status`), its long press
  opening the mobile network settings, the Modem tile over `t715-modem-power` (toggled off and on from the shell on
  the tablet: CP off, then ONLINE in 9.9 s), the call card (no Speaker toggle) and the cell and call
  watchers; omaphone 0.2.3 and omamessages 0.2.2 for aarch64 (the Phone app's dialer opens); a modem
  check in `t715-arm64-health`. Not automatic: a user set up by an earlier build keeps a profile
  without the call card and with the watchers off (the setup's "done" marker): done by hand on the
  tablet (`/root/shell.json.before-modem-ui`); a one-time migration in the user setup would do it.
- An installer that carries the device's own modem files over (the NV copy and its manifest, the
  APN settings, the mobile connection), as for the Wi-Fi profiles; on a fresh root
  shannon-nv-provision makes the NV copy from EFS (read-only) at the first boot. **open**.
- Charging on a wall charger (the driver gives it 1750 mA; the Mac's port gets 450 mA, less than
  eight busy cores and the screen draw): **open** (needs the owner's charger).
- The compositor's first Panfrost → exynos-drm imports fail (non-contiguous buffers, 78 errors in the
  session's first 40 s) and it falls back: measure the cost, compare with the 32-bit dmabuf shim.
  **open**.
- Ledger: a failed attempt that ends in a watchdog reset passes through RECOVERY; the fallback must
  hold across that detour (two previous boots, not one). **done** (`kboot6`; seen on the tablet on
  2026-11-25: a bring-up boot without USB was reset and the 32-bit system came back by itself).
- An on-tablet way to boot the 32-bit system once (today only `t715-arm64-install unloader`, from the
  Mac, for good). **open**.
- A fresh root's first boot has no Wi-Fi (the NVRAM is copied from SYSTEM after brcmfmac probed, and
  brcmfmac cannot be reloaded): copy it in the initramfs, or seed it into the image at install. **open**.
- pstore: archive the records at boot (systemd-pstore is off; ramoops survives warm resets). **open**.
- The user `alarm`'s password is the build's placeholder `changeme`: the owner sets their own. **open**.
- Camera on arm64: the mode tables are on the tablet (copied from the 32-bit root, 2026-11-25); the
  userspace (omacam, libcamera as on the 32-bit image) is not in the arm64 image. **open**.
- The image's time zone and language are UTC and `en_US` by default; the tablet has had the owner's
  own time zone and language since 2026-11-25: an installer should carry them over. **open**.
- `schedutil` under real use; idle power; the battery heat guard of the 32-bit port. **open**.

## Milestone 4: what the 32-bit port had and arm64 does not yet

| function | why | work |
|---|---|---|
| suspend to RAM | the 32-bit code (`EXYNOS_CPU_SUSPEND`, `exynos5433_sleep`) is ARM32 machine code | write an arm64 suspend path without PSCI (the secondaries' power-down, the boot CPU's resume through the loader's EL2 entry) |
| LTE modem, calls, SMS | `SEC_MODEM_V1` depends on ARM | port the driver to arm64 |
| A57 above 1.2 GHz | stage 2 of `CPUFREQ.md` not run on arm64 | the same protocol, owner present |
| Android apps | the 32-bit Waydroid image cannot run (no COMPAT) | a 64-bit Waydroid image |
| A57 hot-unplug | ARM32 code | an arm64 `cpu_die` for the method |

## Milestone 5: a release

- An installer that builds the forged PARAM from each tablet's own PARAM (no PARAM image can be
  distributed: it holds the device's data and Samsung's), writes the slots and the root, and keeps
  the 32-bit system as the way back.
- A fuse check before the cpufreq tables are used (they are this chip's: ASV group 1).

## State on 2026-11-25

**Proven on the tablet.** Milestones 0 to 2 are done: the loader in PARAM starts the full arm64
kernel, and since 2026-11-25 the tablet boots Omarchy 4.5.0-3 on arm64 by itself, at every boot,
from the persistent root `USERDATA/omarchy-arm64`. In Milestone 3, the lines marked **done**: the
"up" mark and the watchdog keeper in the field, the boot screen, the `t715-keys` fix, the modem's CP
up and the modem in the shell, the ledger across a watchdog reset. Display, touch, GPU, Wi-Fi,
Bluetooth, sound, sensors, battery and charger, and the microSD card are there as far as the health
check sees.

**Built or rehearsed only.** No line above is marked **built**. Rehearsed on the Mac before the
tablet: the loader's 27 cases, the modem driver's 76 host vectors, `t715-modem`'s suite in
`check()`. The drivers above are not yet used by a hand: touch gestures, rotation, sound out,
Bluetooth pairing, the camera.

**Open.** The lines marked **open**: about 4 s of text before the splash (an initramfs `t715.quiet`,
at the next kernel build); the modem with a SIM (it needs the owner's SIM); an installer for the
device's own modem files, and one that carries the time zone and language over; charging on a wall
charger (it needs the owner's charger); the first Panfrost → exynos-drm imports; an on-tablet way to
boot the 32-bit system once; a fresh root's first boot without Wi-Fi; pstore archiving; the user's
password; the camera userspace; `schedutil` under real use, idle power and the battery heat guard.
Milestone 4: suspend to RAM, A57 above 1.2 GHz, Android apps, A57 hot-unplug. Milestone 5: the
installer, and a fuse check before the cpufreq tables are used.
