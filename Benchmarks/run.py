#!/usr/bin/env python3
"""Runs each parser on a GTFS feed and prints a Markdown table of median results.

Usage: swift build -c release && python3 run.py <folder with the unzipped feed>
"""
import pathlib, re, statistics, subprocess, sys

RUNS, TIMEOUT = 3, 300
FILES = ["stop_times.txt", "trips.txt"]
PARSERS = [
    ("FastCSV", "BenchFastCSV"),
    ("Naive split", "BenchNaive"),
    ("CSV.swift 2.5.2", "BenchCSVSwift"),
    ("SwiftCSV 0.10.0", "BenchSwiftCSV"),
    ("CodableCSV 0.6.7", "BenchCodableCSV"),
]
TYPED = ("FastCSV, typed accessors", "BenchFastCSVTyped")

root = pathlib.Path(__file__).parent
feed = pathlib.Path(sys.argv[1])
bin_path = pathlib.Path(subprocess.check_output(
    ["swift", "build", "-c", "release", "--show-bin-path"], cwd=root, text=True).strip())


def run(binary, path):
    done = subprocess.run(["/usr/bin/time", "-l", str(bin_path / binary), str(path)],
                          capture_output=True, text=True, timeout=TIMEOUT, check=True)
    seconds, rows, bytes_read = done.stdout.split()
    rss = int(re.search(r"(\d+)\s+maximum resident set size", done.stderr).group(1))
    return float(seconds), int(rows), int(bytes_read), rss / 1_048_576


def row(name, binary, path):
    try:
        results = [run(binary, path) for _ in range(RUNS)]
    except subprocess.TimeoutExpired:
        return f"| {name} | > {TIMEOUT} s | | | |"
    except subprocess.CalledProcessError as error:
        return f"| {name} | failed: {error.stderr.strip()[:80]} | | | |"
    seconds = statistics.median(r[0] for r in results)
    rss = statistics.median(r[3] for r in results)
    return f"| {name} | {seconds:.3f} s | {rss:.0f} MB | {results[0][1]:,} | {results[0][2]:,} |"


for file in FILES:
    path = feed / file
    path.read_bytes()  # warm the page cache
    print(f"\n### {file} ({path.stat().st_size / 1_000_000:.0f} MB)\n", flush=True)
    print("| Parser | Time | Peak memory | Rows | Field bytes |\n|---|---|---|---|---|", flush=True)
    for name, binary in PARSERS + ([TYPED] if file == "stop_times.txt" else []):
        print(row(name, binary, path), flush=True)
