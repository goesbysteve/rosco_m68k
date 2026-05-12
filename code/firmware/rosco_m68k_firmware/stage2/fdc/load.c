/*
 *------------------------------------------------------------
 *                                  ___ ___ _
 *  ___ ___ ___ ___ ___       _____|  _| . | |_
 * |  _| . |_ -|  _| . |     |     | . | . | '_|
 * |_| |___|___|___|___|_____|_|_|_|___|___|_,_|
 *                     |_____|       firmware v2
 * ------------------------------------------------------------
 * Copyright (c)2024 Ross Bamford and contributors
 * See top-level LICENSE.md for licence information.
 *
 * FDC (WD37C65) probe for stage 2 startup
 * ------------------------------------------------------------
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "load.h"
#include "pff.h"
#include "elf.h"
#include "system.h"
#include "fd.h"
#include "machine.h"

extern void print_unsigned(uint32_t num, uint8_t base);

extern uint8_t *kernel_load_ptr;
extern KMain kernel_entry;
static volatile SystemDataBlock * const sdb = (volatile SystemDataBlock * const)0x400;

static const char FILENAME_BIN[] = "/ROSCODE1.BIN";
static const char FILENAME_ELF[] = "/ROSCODE1.ELF";

extern char STAGE2_LOAD[];
extern char _end[];

static const UINT BLOCK_SIZE = 512;

#define MAX_PHDRS 8

static bool load_range_allowed(uintptr_t start, size_t size) {
    if (size == 0) {
        // If there's nothing to load, we don't care, allow it
        return true;
    }

    // Use last instead of `end = start + size` to avoid overflowing
    const size_t offset_last = size - 1;
    if (start > UINTPTR_MAX - offset_last) {
        // Last byte address would overflow
        return false;
    }
    const uintptr_t last = start + offset_last;

    const size_t page_size = 0x1000;
    const uintptr_t page_mask = ~(uintptr_t) (page_size - 1);
    // Dummy variable to get stack pointers
    volatile char dummy;
    const uintptr_t dummy_addr = (uintptr_t) &dummy;
    // Leave at least one full page below the dummy on the stack
    const uintptr_t stack_guard_start = (dummy_addr - page_size) & page_mask;

    // Check for overlaps with reserved memory
    if (last >= 0 && start < 0x2000) {
        // Is in the exception vectors, SDB, EFPT, VDA, or firmware-reserved areas
        return false;
    } else if (last >= (uintptr_t) &STAGE2_LOAD && start < (uintptr_t) &_end) {
        // Is in stage2
        return false;
    } else if (last >= stack_guard_start && start < sdb->memsize) {
        // Is in the stack
        return false;
    }

    return true;
}

static bool fdc_load_kernel_bin(uint32_t start_tick) {
    uint8_t *ptr = kernel_load_ptr;
    uint8_t dot_counter = 0;
    UINT br;
    FRESULT rres = FR_OK;

    while ((rres = pf_read(ptr, BLOCK_SIZE, &br)) == FR_OK && br > 0) {
        ptr += br;
        if (++dot_counter == 8) {
            FW_PRINT_C(".");
            dot_counter = 0;
        }
    }
    FW_PRINT_C("\r\n");

    uint32_t load_size = ptr - kernel_load_ptr;
    if (load_size == 0) {
        if (rres != FR_OK) {
            FW_PRINT_C("FDC: Read error (FR="); print_unsigned(rres, 10); FW_PRINT_C(")\r\n");
        } else {
            FW_PRINT_C("FDC: File has zero bytes\r\n");
        }
        return false;
    }

    uint32_t secs = ((sdb->upticks - start_tick) + 50) / 100;
    FW_PRINT_C("Loaded "); print_unsigned(load_size, 10);
    FW_PRINT_C(" bytes in ~"); print_unsigned(secs ? secs : 1, 10);
    FW_PRINT_C(" sec.\r\n");
    return true;
}

static bool fdc_load_kernel_elf(uint32_t start_tick) {
    Elf32_Ehdr ehdr;
    UINT br;

    if (pf_read(&ehdr, sizeof(Elf32_Ehdr), &br) != FR_OK || br != sizeof(Elf32_Ehdr)) {
        FW_PRINT_C("\r\n*** Couldn't read ELF header\r\n");
        return false;
    }

    if (ehdr.e_ident[EI_MAG0] != ELFMAG0 || ehdr.e_ident[EI_MAG1] != ELFMAG1 ||
        ehdr.e_ident[EI_MAG2] != ELFMAG2 || ehdr.e_ident[EI_MAG3] != ELFMAG3) {
        FW_PRINT_C("\r\n*** Not an ELF file\r\n");
        return false;
    } else if (ehdr.e_ident[EI_CLASS] != ELFCLASS32) {
        FW_PRINT_C("\r\n*** ELF file does not use 32-bit objects\r\n");
        return false;
    } else if (ehdr.e_ident[EI_DATA] != ELFDATA2MSB) {
        FW_PRINT_C("\r\n*** ELF file does not use big-endian objects\r\n");
        return false;
    } else if (ehdr.e_ident[EI_VERSION] != EV_CURRENT) {
        FW_PRINT_C("\r\n*** ELF file does not use a compatible version\r\n");
        return false;
    } else if (ehdr.e_type != ET_EXEC) {
        FW_PRINT_C("\r\n*** ELF file is not an executable\r\n");
        return false;
    } else if (ehdr.e_machine != EM_68K) {
        FW_PRINT_C("\r\n*** ELF file is not for Motorola 68000\r\n");
        return false;
    } else if (ehdr.e_version != EV_CURRENT) {
        FW_PRINT_C("\r\n*** ELF file does not use a compatible version\r\n");
        return false;
    } else if (ehdr.e_ehsize != sizeof(Elf32_Ehdr)) {
        FW_PRINT_C("\r\n*** ELF header has unexpected size\r\n");
        return false;
    } else if (ehdr.e_phentsize != sizeof(Elf32_Phdr)) {
        FW_PRINT_C("\r\n*** ELF program header entries have unexpected size\r\n");
        return false;
    } else if (ehdr.e_phoff == 0 || ehdr.e_phnum == 0) {
        FW_PRINT_C("\r\n*** ELF file has no program header table\r\n");
        return false;
    }

    if (pf_lseek(ehdr.e_phoff) != FR_OK) {
        FW_PRINT_C("\r\n*** Failed to seek to program headers\r\n");
        return false;
    }

    Elf32_Half nph = ehdr.e_phnum > MAX_PHDRS ? MAX_PHDRS : ehdr.e_phnum;
    Elf32_Phdr phdrs[MAX_PHDRS];
    if (pf_read(phdrs, nph * sizeof(Elf32_Phdr), &br) != FR_OK || br != nph * sizeof(Elf32_Phdr)) {
        FW_PRINT_C("\r\n*** Couldn't read ELF program headers\r\n");
        return false;
    }

    uint32_t load_size = 0;
    for (Elf32_Half i = 0; i < nph; i++) {
        Elf32_Phdr *phdr = &phdrs[i];
        if (phdr->p_type != PT_LOAD) {
            continue;
        }

        if (!load_range_allowed(phdr->p_vaddr, phdr->p_memsz)) {
            FW_PRINT_C("\r\n*** Segment would overwrite firmware memory\r\n");
            return false;
        }

        if (pf_lseek(phdr->p_offset) != FR_OK) {
            FW_PRINT_C("\r\n*** Failed to seek to loadable segment\r\n");
            return false;
        }

        if (phdr->p_filesz > 0) {
            if (pf_read((void *)phdr->p_vaddr, phdr->p_filesz, &br) != FR_OK || br != phdr->p_filesz) {
                FW_PRINT_C("\r\n*** Couldn't read loadable segment\r\n");
                return false;
            }
            FW_PRINT_C(".");
        }

        memset((void *)(phdr->p_vaddr + phdr->p_filesz), 0, phdr->p_memsz - phdr->p_filesz);
        load_size += phdr->p_filesz;
    }
    FW_PRINT_C("\r\n");

    if (ehdr.e_entry == 0) {
        FW_PRINT_C("*** ELF file has no entry point\r\n");
        return false;
    }
    kernel_entry = (KMain)ehdr.e_entry;

    uint32_t secs = ((sdb->upticks - start_tick) + 50) / 100;
    FW_PRINT_C("Loaded ");
    print_unsigned(load_size, 10);
    FW_PRINT_C(" bytes in ~");
    print_unsigned(secs ? secs : 1, 10);
    FW_PRINT_C(" sec.\r\n");

    return true;
}

bool fdc_load_kernel(void) {
    if (!FD_check_support()) {
        FW_PRINT_C("Warning: No FDC support in ROM - This may indicate your ROMs are not built correctly!\r\n");
        return false;
    }

    FATFS fs;
    FRESULT mres = pf_mount(&fs);
    if (mres != FR_OK) {
        switch (mres) {
        case FR_NOT_READY:   FW_PRINT_C("FDC: Drive not ready\r\n");           break;
        case FR_DISK_ERR:    FW_PRINT_C("FDC: Disk read error\r\n");           break;
        case FR_NO_FILESYSTEM: FW_PRINT_C("FDC: No FAT filesystem on floppy\r\n"); break;
        default:             FW_PRINT_C("FDC: Mount failed\r\n");              break;
        }
        return false;
    }

    FW_PRINT_C("Floppy disk:\r\n");
    uint32_t start_tick = sdb->upticks;

    if (pf_open(FILENAME_BIN) == FR_OK) {
        FW_PRINT_C("  Loading \"" );
        FW_PRINT_C(FILENAME_BIN);
        FW_PRINT_C("\"");
        return fdc_load_kernel_bin(start_tick);
    } else if (pf_open(FILENAME_ELF) == FR_OK) {
        FW_PRINT_C("  Loading \"");
        FW_PRINT_C(FILENAME_ELF);
        FW_PRINT_C("\"");
        return fdc_load_kernel_elf(start_tick);
    } else {
        FW_PRINT_C("  No bootable image\r\n");
        return false;
    }
}
