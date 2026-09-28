"""Embeddings + cosine similarity. Local model shown; hosted API is the same shape."""
from __future__ import annotations

import numpy as np
from sentence_transformers import SentenceTransformer

# Small, fast, runs on CPU
_MODEL = SentenceTransformer("all-MiniLM-l6-v2")

def embed(text:str) -> np.ndarray:
    # A hosted embeddings API (ex  Bedrock, provider APIs) returns a vector
    # in exactly this shape - swap this line for the API call, keep the rest.
    return _MODEL.encode(text, convert_to_numpy=True)


def cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    denom = float(np.linalg.norm(a) * np.linalg.norm(b))
    if denom == 0.0:
        return 0.0
    return float(np.dot(a,b)/denom)

def similarity(text_a:str, text_b:str) -> float:
    return cosine_similarity(embed(text_a), embed(text_b))