import pytest

from textstats.config import StatsConfig
from textstats.stats import compute_stats, tokenize


def test_tokenize_lowercase_by_default() -> None:
    assert tokenize("The THE the") == ["the", "the", "the"]


def test_tokenize_preserves_case_when_asked() -> None:
    assert tokenize("The THE", ignore_case=False) == ["The", "THE"]


def test_compute_stats_counts_and_ranks() -> None:
    stats = compute_stats("a a a b b c", StatsConfig(top_n=2))
    assert stats.total_words == 6
    assert stats.top_words == [("a", 3), ("b", 2)]
    assert stats.unique_words == 3


@pytest.mark.parametrize(
    argnames=("text", "min_length", "expected_total"),
    argvalues=[("a bb ccc", 1, 3), ("a bb ccc", 2, 2), ("a bb ccc", 3, 1)],
)
def test_min_length_filters(text: str, min_length: int, expected_total: int) -> None:
    stats = compute_stats(text=text, config=StatsConfig(min_length=min_length))
    assert stats.total_words == expected_total


def test_config_rejectd_bad_top_n() -> None:
    with pytest.raises(ValueError):
        StatsConfig(top_n=0)
