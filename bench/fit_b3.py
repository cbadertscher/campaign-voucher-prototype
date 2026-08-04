#!/usr/bin/env python3
"""B3 post-processing: OLS fit of gas vs. v and the resulting v_max under the
L1 30M block gas limit. Reads the CSVs written by test/gas/B3_OutflowSlope.t.sol.

Usage: python3 bench/fit_b3.py gas-reports/b3_batchTransfer.csv gas-reports/b3_redeem.csv
"""

import csv
import os
import sys

BLOCK_GAS_LIMIT = 30_000_000


def read_csv(path):
    xs, ys = [], []
    with open(path) as f:
        for row in csv.DictReader(f):
            xs.append(int(row["v"]))
            ys.append(int(row["gasUsed"]))
    return xs, ys


def fit(xs, ys):
    n = len(xs)
    sx, sy = sum(xs), sum(ys)
    sxx = sum(x * x for x in xs)
    sxy = sum(x * y for x, y in zip(xs, ys))
    slope = (n * sxy - sx * sy) / (n * sxx - sx * sx)
    intercept = (sy - slope * sx) / n
    return slope, intercept


def report(label, path):
    xs, ys = read_csv(path)
    slope, intercept = fit(xs, ys)
    v_max = int((BLOCK_GAS_LIMIT - intercept) // slope)
    print(f"{label}: slope={slope:.1f} gas/voucher, intercept={intercept:.1f} gas, v_max={v_max}")


if __name__ == "__main__":
    for path in sys.argv[1:]:
        label = os.path.splitext(os.path.basename(path))[0]
        report(label, path)
