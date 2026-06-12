# rosco_m68k FAT12 Filesystem Test
# High-level test using Chan FatFs API

ROSCO_M68K_DEFAULT_DIR=../../..

ifndef ROSCO_M68K_DIR
$(info NOTE: ROSCO_M68K_DIR not set, using: $(ROSCO_M68K_DEFAULT_DIR))
ROSCO_M68K_DIR=$(ROSCO_M68K_DEFAULT_DIR)
endif

-include $(ROSCO_M68K_DIR)/code/software/software.mk

# Paths to FDC modules
FDC_DIR=$(ROSCO_M68K_DEFAULT_DIR)/code/software/fdc
FF_DIR=$(FDC_DIR)/fatfs

# Extra flags for includes
EXTRA_CFLAGS += -I$(FDC_DIR) -I$(FF_DIR)

# Build FDC TRAP wrappers (from fdc/)
fdc.o: $(FDC_DIR)/fdc.asm
	$(VASM) $(VASMFLAGS) $(EXTRA_VASMFLAGS) -L fdc.lst -o $@ $<

# Build FatFs core library (from fdc/fatfs/)
# Note: -Wno-error=overflow allows DDEM (0xE5) assignment to signed char
# This keeps ff.c unmodified from the original Chan FatFs distribution
ff.o: $(FF_DIR)/ff.c
	$(CC) $(CFLAGS) $(EXTRA_CFLAGS) -Wno-error=overflow -c -o $@ $<

# Build diskio bridge layer (from fdc/fatfs/)
diskio.o: $(FF_DIR)/diskio.c
	$(CC) $(CFLAGS) $(EXTRA_CFLAGS) -c -o $@ $<

# Link all objects together
$(ELF): fdc.o ff.o diskio.o
