;------------------------------------------------------------
;                                  ___ ___ _   
;  ___ ___ ___ ___ ___       _____|  _| . | |_ 
; |  _| . |_ -|  _| . |     |     | . | . | '_|
; |_| |___|___|___|___|_____|_|_|_|___|___|_,_| 
;                     |_____|       firmware v2
;------------------------------------------------------------
; Copyright (c)2024 Ross Bamford and contributors
; See top-level LICENSE.md for licence information.
;
; TRAP #13 wrapper for FDC firmware presence check (FC 20).
; Returns 1 if the FDC driver is installed in firmware
; ($1234FEDC CHECK_SUCCESS magic), 0 otherwise.
;------------------------------------------------------------

FD_check_support::
    move.l  #20,D0
    trap    #13
    cmp.l   #$1234FEDC,D0
    beq.s   .ok
    move.l  #0,D0
    bra.s   .done
.ok
    move.l  #1,D0
.done
    rts
