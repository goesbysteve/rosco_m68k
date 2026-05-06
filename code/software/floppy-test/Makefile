# Make rosco_m68k FDC address decode test
#
# Copyright (c) 2020 Xark
# MIT LICENSE

ROSCO_M68K_DEFAULT_DIR=../../..

ifndef ROSCO_M68K_DIR
$(info NOTE: ROSCO_M68K_DIR not set, using libs: $(ROSCO_M68K_DEFAULT_DIR)/code/software/libs)
ROSCO_M68K_DIR=$(ROSCO_M68K_DEFAULT_DIR)
else
$(info NOTE: Using ROSCO_M68K_DIR libs in: $(ROSCO_M68K_DIR))
endif

-include $(ROSCO_M68K_DIR)/code/software/software.mk

EXTRA_LIBS=

EXTRA_CFLAGS += -I$(ROSCO_M68K_DEFAULT_DIR)/code/software/fdc

FDC_DIR=$(ROSCO_M68K_DEFAULT_DIR)/code/software/fdc

fdc.o: $(FDC_DIR)/fdc.asm
	$(VASM) $(VASMFLAGS) $(EXTRA_VASMFLAGS) -L fdc.lst -o $@ $<

$(ELF): fdc.o
