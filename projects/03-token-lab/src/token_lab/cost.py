"""Cost estimation. Prices change constantly - pass them in, never hard code"""
from __future__ import annotations

from dataclasses import dataclass

@dataclass(frozen=True, slots=True)
class ModelPrice:
    """Price in dollars per 1000 tokens. Look up current values per model."""
    input_per_1k: float
    output_per_1k: float

def estimate_cost(input_tokens:int, output_tokens:int, price:ModelPrice) -> float:
    return (input_tokens / 1000 * price.input_per_1k
            + output_tokens / 1000 * price.output_per_1k)
    