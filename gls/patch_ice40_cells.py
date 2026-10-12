#!/usr/bin/env python3
"""Make a gate-level-simulation-friendly copy of Yosys's iCE40 cell models.

Yosys's SB_IO model computes its pin values in `always @*` blocks. In
Verilog those blocks only run when an input *changes*, so a pin whose
value never changes after time 0 (e.g. a flip-flop that starts at 0 and
is reset to 0) is left at X forever in simulation. Real silicon has no
such problem. This script adds a one-time "kick" that evaluates both
blocks once, just after time 0. Nothing else in the model is changed.

usage: patch_ice40_cells.py <yosys cells_sim.v> <output .v>
"""
import sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()

din_old = """	always @* begin
		if (!PIN_TYPE[1] || !LATCH_INPUT_VALUE)"""
din_new = """	reg gls_kick = 1'b0;                 // GLS patch: evaluate once after t=0
	initial #1 gls_kick = 1'b1;
	always @(PACKAGE_PIN or LATCH_INPUT_VALUE or din_q_0 or din_q_1 or gls_kick) begin
		if (!PIN_TYPE[1] || !LATCH_INPUT_VALUE)"""

dout_old = """	always @* begin
		if (PIN_TYPE[3])"""
dout_new = """	always @(D_OUT_0 or dout_q_0 or dout_q_1 or outclk_delayed_2 or gls_kick) begin
		if (PIN_TYPE[3])"""

for old, new in ((din_old, din_new), (dout_old, dout_new)):
    if text.count(old) < 1:
        sys.exit("patch_ice40_cells.py: pattern not found -- Yosys cell model changed?")
    text = text.replace(old, new, 1)   # only the first occurrence = SB_IO

open(dst, "w").write(text)
print(f"wrote {dst}")
