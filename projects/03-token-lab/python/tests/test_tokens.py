from token_lab.tokens import count_tokens


def test_count_matches_tiktoken_cl100k() -> None:
    assert count_tokens("hello world") == 2
