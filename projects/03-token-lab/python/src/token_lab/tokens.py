"""Token counting. Deterministic and knowable before you ever call a model"""

from __future__ import annotations
import tiktoken

def count_tokens(text:str, encoding:str = "cl100k_base") -> int:
    enc = tiktoken.get_encoding(encoding)
    return len(enc.encode(text))
