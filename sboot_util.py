from __future__ import annotations

import struct

_SPLIT_TAIL_SIGNATURE = bytes.fromhex("10 20 42 e2 02 c0 6c e0 00 c0 83 e5 ee ff ff ea")

def find_large_heap_sentinel(sboot: bytes) -> int:
  candidates: list[int] = []
  start = 0
  while (hit := sboot.find(_SPLIT_TAIL_SIGNATURE, start)) != -1:
    start = hit + 1
    literal = hit + len(_SPLIT_TAIL_SIGNATURE)
    if literal + 16 > len(sboot):
      continue
    sentinel, heap_base, mode_flag, small_sentinel = struct.unpack_from("<4I", sboot, literal)
    if (
      sentinel % 4 == 0
      and small_sentinel == sentinel + 16
      and heap_base == 0x24E00000
      and mode_flag % 4 == 0
      and 0x23E00000 <= sentinel < 0x24000000
    ):
      candidates.append(sentinel)
  if len(candidates) != 1:
    raise ValueError(f"S-Boot allocator signature yielded {len(candidates)} valid targets; expected one")
  return candidates[0]
