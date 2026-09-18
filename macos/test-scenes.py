#!/usr/bin/env python3
"""Exercise real scene packages with the bundled XPC/GPU self-test."""
import argparse
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("library", type=Path)
    parser.add_argument("assets", type=Path)
    parser.add_argument("--ids", nargs="*")
    parser.add_argument("--output", type=Path, default=Path("macos/.build/verification/matrix"))
    args = parser.parse_args()
    executable = Path(__file__).resolve().parent / ".build/VividSceneTest.app/Contents/MacOS/vivid-macos"
    args.output.mkdir(parents=True, exist_ok=True)
    results = []
    for manifest in sorted(args.library.glob("*/project.json")):
        project = json.loads(manifest.read_text(encoding="utf-8"))
        if project.get("type", "").lower() != "scene":
            continue
        identity = manifest.parent.name
        if args.ids and identity not in args.ids:
            continue
        output = args.output / identity
        try:
            run = subprocess.run(
                [str(executable), str(manifest.parent), str(args.assets), str(output.resolve())],
                capture_output=True, text=True, timeout=110,
            )
            result = {"id": identity, "title": project.get("title", ""), "passed": run.returncode == 0,
                      "returncode": run.returncode, "output": run.stdout + run.stderr}
        except subprocess.TimeoutExpired:
            result = {"id": identity, "passed": False, "output": "Process exceeded 110 seconds"}
        results.append(result)
        print(f"{identity}: {result['output'].strip()}", flush=True)
        (args.output / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")
    passed = sum(result["passed"] for result in results)
    print(f"Scene matrix: {passed}/{len(results)} passed", flush=True)
    return 0 if results and passed == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
