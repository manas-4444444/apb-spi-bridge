#!/usr/bin/env python3
"""Summarise Verilator line / branch / toggle coverage for the two RTL files.

Usage:  python3 cov_report.py coverage.dat

Documented exclusions (bits the design intentionally ignores or ties to 0):
  PADDR[31:8], PWDATA[31:8]  - only the low byte is decoded
  PRDATA[31:8]               - registers are 8 bits wide, upper bits are always 0
"""
import re
import sys

RTL_FILES = ("spi_master.v", "apb_spi_wrapper.v")


def field(key, name):
    m = re.search("\x01" + name + "\x02([^\x01]*)", key)
    return m.group(1) if m else ""


def excluded(obj):
    m = re.match(r"(PADDR|PWDATA|PRDATA)\[(\d+)\]", obj)
    return bool(m) and int(m.group(2)) >= 8


def main(path):
    text = open(path, encoding="latin-1").read()
    points = re.findall(r"C '([^']*)' (\d+)", text)
    stats, missed = {}, []
    for key, count in points:
        fname = field(key, "f").split("/")[-1]
        if fname not in RTL_FILES:
            continue
        kind = field(key, "page").split("/")[0].replace("v_", "")
        obj = field(key, "o")
        if kind == "toggle" and excluded(obj):
            continue
        hit_tot = stats.setdefault((fname, kind), [0, 0])
        hit_tot[1] += 1
        if int(count) > 0:
            hit_tot[0] += 1
        else:
            missed.append(f"{fname}:{field(key, 'l')} {kind} {obj}")

    print(f"{'file':20} {'type':8} {'covered':>12}")
    for (fname, kind), (hit, tot) in sorted(stats.items()):
        print(f"{fname:20} {kind:8} {hit:>4}/{tot:<4} {100.0 * hit / tot:6.1f}%")
    if missed:
        print("\nNot covered:")
        for m in missed:
            print("  " + m)
    else:
        print("\nAll coverage points hit.")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "coverage.dat")
