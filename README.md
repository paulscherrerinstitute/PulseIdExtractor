# Pulse ID Extractor

## PulseidExtractor Core Module

VHDL module to extract the pulse-id (or any other data item)
from a EVR320 data stream. A sequence of bytes from the
stream is converted into a parallel word raising a 'strobe'
signal when the last byte arrives.

Statistics counters optionally check for occurrence of
certain conditions:
 - not all data bytes arrived
 - pulse-id not in sequence (optional)
 - no update in watchdog period (optional)

## TMEM Wrapper for Atomic Readout

The `PulseidAtomicTmem.vhd` wrapper supports reading pulse-id
as well as time-stamps from an EVR320 stream as an atomic
entity (for software).

A 'freeze' bit can be set by software to inhibit updates while
software reads the pulse-id and time-stamp. Updates are re-enabled
when software clears the 'freeze' bit.
