set led_strip_i2c_fw_files { \
  "ioxos_mpc_master_i2c_ctl_pkg.vhd" \
  "MpcI2cSequencerPkg.vhd" \
  "InpDebouncer.vhd" \
  "ioxos_mpc_master_i2c_ctl.vhd" \
  "MpcI2cSequencer.vhd" \
  "LedStripController.vhd" \
  "PulseidExtractor.vhd" \
}

set led_strip_i2c_location "[file dirname [info script]]"

proc led_strip_i2c_add_srcs { pre } {
  global led_strip_i2c_fw_files
  global led_strip_i2c_location
  set led_strip_i2ch "[file dirname [info script]]"
  foreach f $led_strip_i2c_fw_files {
    xfile add "$pre$led_strip_i2c_location/$f"
  }
}
