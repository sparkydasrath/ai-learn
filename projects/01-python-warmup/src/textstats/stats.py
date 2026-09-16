"""Pure functions: text in, stats out. No I/O."""

from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass

from textstats.config import StatsConfig

_WORD_RE = re.compile(r"[A-Za-z']+")


@dataclass(frozen=True, slots=True)
class TextStats:
    total_words: int
    unique_words: int
    top_words: list[tuple[str, int]]


def tokenize(text: str, *, ignore_case: bool = True) -> list[str]:
    words = _WORD_RE.findall(text)
    if ignore_case:
        words = [w.lower() for w in words]
    return words


def compute_stats(text: str, config: StatsConfig) -> TextStats:
    words = [
        w for w in tokenize(text, ignore_case=config.ignore_case) if len(w) >= config.min_length
    ]
    counts = Counter(words)
    return TextStats(
        total_words=len(words), unique_words=len(counts), top_words=counts.most_common(config.top_n)
    )
