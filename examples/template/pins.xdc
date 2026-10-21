# Pin constraints for NAME. TE0701 Pmod J5 -> TE0820 bank 65 (HP, VCCO = VIOTA, must be 1.8 V):
#   J5.1 N6   J5.2 N7   J5.3 L3   J5.4 L2   J5.7 K1   J5.8 L1   J5.9 M6   J5.10 L5
set_property -dict {PACKAGE_PIN N6 IOSTANDARD LVCMOS18} [get_ports led]
