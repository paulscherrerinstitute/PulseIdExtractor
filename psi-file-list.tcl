set ledstrip_support_fw_files { \
  "ioxos_mpc_master_i2c_ctl_pkg.vhd" \
  "MpcI2cSequencerPkg.vhd" \
  "InpDebouncer.vhd" \
  "ioxos_mpc_master_i2c_ctl.vhd" \
  "MpcI2cSequencer.vhd" \
  "LedStripController.vhd" \
  "PulseidExtractor.vhd" \
}

set ledstrip_support_location "[file dirname [info script]]"

proc ledstrip_support_add_srcs { pre } {
  global ledstrip_support_fw_files
  global ledstrip_support_location
  set ledstripSupPath "[file dirname [info script]]"
  foreach f $ledstrip_support_fw_files {
    xfile add "$pre$ledstrip_support_location/$f"
  }
}
