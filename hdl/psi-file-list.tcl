set pulseid_extractor_fw_files { \
  "Evr320StreamPkg.vhd"   \
  "PulseidExtractor.vhd"  \
  "PulseidAtomic.vhd"     \
  "PulseidAtomicTmem.vhd" \
  "SyncCmpSlow.vhd"       \
}

set pulseid_extractor_location "[file dirname [info script]]"

proc pulseid_extractor_add_srcs { pre } {
  global pulseid_extractor_fw_files
  global pulseid_extractor_location
  foreach f $pulseid_extractor_fw_files {
    xfile add "$pre$pulseid_extractor_location/$f"
  }
}
