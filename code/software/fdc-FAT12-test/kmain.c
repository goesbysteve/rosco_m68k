/*
 * rosco_m68k FAT12 Floppy Filesystem Test
 * High-level test using Chan FatFs API
 */

#include <stdio.h>
#include <string.h>
#include <basicio.h>
#include "ff.h"

static FATFS fs;
static FIL file;
static DIR dir;
static FILINFO fno;
static BYTE buffer[512];

void kmain(void) {
    FRESULT res;
    UINT br, bw;

    printf("=== rosco_m68k FAT12 Filesystem Test ===\r\n\r\n");

    /* Mount filesystem */
    printf("Mounting FAT12 filesystem...\r\n");
    res = f_mount(&fs, "", 1);  /* 1 = mount now */
    if (res != FR_OK) {
        printf("ERROR: f_mount failed with code %d\r\n", res);
        printf("  Possible causes:\r\n");
        printf("  - No floppy disk inserted\r\n");
        printf("  - Disk not formatted as FAT12\r\n");
        printf("  - FDC hardware not responding\r\n");
        return;
    }
    printf("Mount successful!\r\n\r\n");

    /* List root directory */
    printf("--- Root Directory Listing ---\r\n");
    res = f_opendir(&dir, "/");
    if (res == FR_OK) {
        int count = 0;
        while (1) {
            res = f_readdir(&dir, &fno);
            if (res != FR_OK || fno.fname[0] == 0) break;  /* Error or end */

            count++;
            if (fno.fattrib & AM_DIR) {
                printf("  <DIR>  %s\r\n", fno.fname);
            } else {
                printf("  %8lu  %s\r\n", fno.fsize, fno.fname);
            }
        }
        f_closedir(&dir);
        printf("Total: %d items\r\n", count);
    } else {
        printf("ERROR: f_opendir failed with code %d\r\n", res);
    }
    printf("\r\n");

    /* Try to read a test file */
    printf("--- Read Test: TEST.TXT ---\r\n");
    res = f_open(&file, "TEST.TXT", FA_READ);
    if (res == FR_OK) {
        printf("File opened successfully\r\n");

        res = f_read(&file, buffer, sizeof(buffer)-1, &br);
        if (res == FR_OK && br > 0) {
            buffer[br] = '\0';  /* Null terminate */
            printf("Read %u bytes:\r\n", br);
            printf("--- File Contents ---\r\n");
            printf("%s", buffer);
            if (buffer[br-1] != '\n') {
                printf("\r\n");
            }
            printf("--- End of File ---\r\n");
        } else {
            printf("ERROR: f_read failed (code=%d, br=%u)\r\n", res, br);
        }

        f_close(&file);
    } else {
        printf("Note: TEST.TXT not found (code=%d)\r\n", res);
        printf("Create a file named TEST.TXT on your floppy to test reading.\r\n");
    }
    printf("\r\n");

    /* Try to write a file (if write is enabled) */
#if FF_FS_READONLY == 0
    printf("--- Write Test: HELLO.TXT ---\r\n");
    res = f_open(&file, "HELLO.TXT", FA_WRITE | FA_CREATE_ALWAYS);
    if (res == FR_OK) {
        const char *msg = "Hello from rosco_m68k FAT12!\r\nTimestamp: 2026-06-07\r\n";

        res = f_write(&file, msg, strlen(msg), &bw);
        if (res == FR_OK) {
            printf("Wrote %u bytes to HELLO.TXT\r\n", bw);
        } else {
            printf("ERROR: f_write failed with code %d\r\n", res);
        }

        f_close(&file);
    } else {
        printf("ERROR: Could not create HELLO.TXT (code=%d)\r\n", res);
    }
    printf("\r\n");

    /* Try to create a directory */
    printf("--- Directory Creation Test: TESTDIR ---\r\n");
    res = f_mkdir("TESTDIR");
    if (res == FR_OK) {
        printf("Directory TESTDIR created successfully\r\n");
    } else if (res == FR_EXIST) {
        printf("Directory TESTDIR already exists\r\n");
    } else {
        printf("ERROR: f_mkdir failed with code %d\r\n", res);
    }
#else
    printf("Write tests skipped (FF_FS_READONLY=1 in ffconf.h)\r\n");
#endif

    printf("\r\n=== Test Complete ===\r\n");

    /* Unmount filesystem before exit */
    f_mount(NULL, "", 0);
}
