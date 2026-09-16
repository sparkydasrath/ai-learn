"""Thin I/O shell around the pure core."""

from __future__ import annotations

import argparse
import sys

from textstats.config import StatsConfig
from textstats.stats import compute_stats


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Text statistics tool.")
    parser.add_argument("path", nargs="?", help="File to read; omit to read stdin.")
    parser.add_argument("--top", type=int, default=10, help="How many top words.")
    parser.add_argument("--min-length", type=int, default=1)
    parser.add_argument(
        "--no-ignore-case",
        action="store_true",
        help="Treat casing as significant.",
    )
    parser.add_argument(
        "--no_ignore_case",
        dest="no_ignore_case",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    args = parser.parse_args(argv)

    text = _read_input(args.path)
    config = StatsConfig(
        top_n=args.top,
        min_length=args.min_length,
        ignore_case=not args.no_ignore_case,
    )
    stats = compute_stats(text, config)

    print(f"Total words:  {stats.total_words}")
    print(f"Unique words: {stats.unique_words}")
    print(f"Top {config.top_n}:")
    for word, count in stats.top_words:
        print(f"  {count:>6}  {word}")
    return 0


def _read_input(path: str | None) -> str:
    if path is None:
        return sys.stdin.read()
    with open(path, encoding="utf-8") as f:
        return f.read()


if __name__ == "__main__":
    raise SystemExit(main())
