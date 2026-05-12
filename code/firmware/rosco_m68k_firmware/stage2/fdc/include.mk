OBJECTS+=fdc/load.o fdc/fdc_asm.o fdc/diskio.o fdc/pff.o
DEFINES+=-DFDC_LOADER
INCLUDES+=-Ifdc/include
