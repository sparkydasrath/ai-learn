"""Configuaration model, validated at the trust boundary."""

from pydantic import BaseModel, Field


class StatsConfig(BaseModel):
    top_n: int = Field(default=10, ge=1, le=1000)
    min_length: int = Field(default=1, ge=1)
    ignore_case: bool = True
