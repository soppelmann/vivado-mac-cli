# Phase 1 — TE0820 (xczu2eg-sfvc784-1-e) on a TE0701 carrier, Pmod J5.
# J5 is PL I/O in bank 65 (HP bank: VCCO = carrier rail VIOTA, which MUST be 1.8 V:
# J17 open + J16 1-2 routes VIOTA to FMC_VADJ, S4 = 1.8 V as delivered). Measure J5 pin 6.
# Mapping derived from TE0701-06 TRM (J5 -> JB2), the 4x5 mirror rule (JB odd n <-> JM n+1)
# and the TE0820 REV05 schematic (JM2 -> bank-65 net -> package pin). Verify on first use.
#
#   J5.1  PA1_P  JB2-27 -> JM2-28  B65_L15_N  N6
#   J5.2  PA1_N  JB2-25 -> JM2-26  B65_L15_P  N7
#   J5.3  PA2_P  JB2-26 -> JM2-25  B65_L12_P  L3
#   J5.4  PA2_N  JB2-28 -> JM2-27  B65_L12_N  L2
#   J5.7  PA0_P  JB2-23 -> JM2-24  B65_L7_N   K1
#   J5.8  PA0_N  JB2-21 -> JM2-22  B65_L7_P   L1
#   J5.9  PA3_P  JB2-22 -> JM2-21  B65_L14_P  M6
#   J5.10 PA3_N  JB2-24 -> JM2-23  B65_L14_N  L5
#   J5.5/11 = GND, J5.6/12 = VIOTA

# LED: J5 pin 1 -> series resistor (~100 ohm at 1.8 V) -> LED -> GND (J5 pin 5)
set_property -dict {PACKAGE_PIN N6 IOSTANDARD LVCMOS18} [get_ports led]
# Button: J5 pin 3 -> push button -> GND (J5 pin 5); internal pull-up, active-low (hello.sv default)
set_property -dict {PACKAGE_PIN L3 IOSTANDARD LVCMOS18 PULLUP true} [get_ports btn]
