#!/usr/bin/env python3
"""Runs each parser on a GTFS feed, prints a Markdown table of median results
and saves them to results.json, which charts.py turns into the README charts.

Usage: swift build -c release && python3 run.py <folder with the unzipped feed>
"""
import json, pathlib, re, statistics, subprocess, sys

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


def measure(name, binary, path):
    try:
        results = [run(binary, path) for _ in range(RUNS)]
    except subprocess.TimeoutExpired:
        print(f"| {name} | > {TIMEOUT} s | | | |", flush=True)
        return None
    except subprocess.CalledProcessError as error:
        print(f"| {name} | failed: {error.stderr.strip()[:80]} | | | |", flush=True)
        return None
    seconds = statistics.median(r[0] for r in results)
    rss = statistics.median(r[3] for r in results)
    print(f"| {name} | {seconds:.3f} s | {rss:.0f} MB | {results[0][1]:,} | {results[0][2]:,} |",
          flush=True)
    return {"parser": name, "seconds": round(seconds, 3), "memory_mb": round(rss)}


report = {"files": []}
for file in FILES:
    path = feed / file
    path.read_bytes()  # warm the page cache
    size_mb = path.stat().st_size / 1_000_000
    print(f"\n### {file} ({size_mb:.0f} MB)\n", flush=True)
    print("| Parser | Time | Peak memory | Rows | Field bytes |\n|---|---|---|---|---|", flush=True)
    results = [measure(name, binary, path) for name, binary in PARSERS]
    if file == "stop_times.txt":
        measure(*TYPED, path)  # different workload: printed, not charted
    report["files"].append({
        "name": file,
        "size_mb": round(size_mb),
        "results": [r for r in results if r],
    })

(root / "results.json").write_text(json.dumps(report, indent=2) + "\n")
