# Patch: `pff.c` `check_fs` — pre-DOS 4.0 FAT12/16 compatibility

## Problem

`pf_mount()` → `check_fs()` in Petit FatFs R0.03a rejects valid FAT12/16
floppy images created by pre-DOS 4.0 (pre-1991) formatters that leave
`BS_FilSysType` (offset 54) blank. The existing check:

```c
ld_word(buf) == 0x4146   /* "FA" — start of "FAT12   " / "FAT16   " */
```

fails for these images, returning 1 ("valid boot record but not FAT") which
propagates to `FR_NO_FILESYSTEM` from `pf_mount`.

Affected images include disks formatted by NETDRIVE and other DOS 3.x era
utilities. These are entirely valid FAT12/16 volumes with correct BPB
geometry — they simply predate the extended BPB introduced in DOS 4.0 (1988)
that standardised `BS_FilSysType`.

Full FatFs R0.15 already contains this fallback, with the comment:
> "FAT volumes created in the early MS-DOS era lack BS_55AA and
> BS_FilSysType, so FAT VBR needs to be identified without them."

## Fix

Added a BPB geometry fallback to `check_fs()` in `pff.c`, after the
`BS_FilSysType` string checks fail. Validates seven BPB fields all present
since MS-DOS 2.0 (1983):

| Field | BPB offset | Check |
|---|---|---|
| `BS_JmpBoot` | 0 | `0xEB`, `0xE9`, or `0xE8` (valid x86 JMP opcode) |
| `BPB_BytsPerSec` | 11 | 512–4096 and a power of 2 |
| `BPB_SecPerClus` | 13 | non-zero and a power of 2 |
| `BPB_RsvdSecCnt` | 14 | non-zero |
| `BPB_NumFATs` | 16 | 1 or 2 |
| `BPB_RootEntCnt` | 17 | non-zero |
| `BPB_FATSz16` | 22 | non-zero |

If all seven pass, the sector is accepted as a FAT12/16 VBR.

## Implementation notes

- `buf` is `BYTE buf[36]` in the `pf_mount` caller; reading 24 bytes (offset 0)
  is safe.
- `disk_readp`, `ld_word`, and `_FS_32ONLY` are all already used in this file —
  no new dependencies.
- Guard is `!_FS_32ONLY`, matching the existing FAT12/16 path. FAT32 images
  always have `BS_FilSysType32` populated, so no FAT32 fallback is needed.
- The `0xAA55` boot sector signature check has already passed before this code
  is reached, so a random sector cannot accidentally match.
- No new `#define` constants required.

## Scope

- One function modified: `check_fs()` in `pff.c`.
- No changes to `pf_mount`, `diskio.c`, or any caller.
- No changes to the full FatFs copy under `code/software/fdc/fatfs/` (separate
  library used only by user-space software, not stage2).

## Verification

1. Build firmware with `WITH_FDC=true` — no new warnings expected.
2. Boot with a pre-DOS 4.0 formatted 720K image → `pf_mount()` returns
   `FR_OK` and proceeds to file load.
3. Boot with a modern FAT12 image (with `BS_FilSysType` set) — still hits the
   existing fast path; fallback is never reached.

## No upstream patch available

The only official patch for Petit FatFs R0.03a (`pff3a_p1.diff`, May 2021)
fixes a CP857 character table bug and a compiler warning only. Elm-Chan's
position is that non-compliant images should be reformatted. This local patch
is therefore intentional and permanent for rosco_m68k.
