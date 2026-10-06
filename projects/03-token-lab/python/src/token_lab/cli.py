from __future__ import annotations

import argparse

from token_lab.cost import ModelPrice, estimate_cost
from token_lab.embeddings import similarity
from token_lab.tokens import count_tokens


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Token / cost / similarity lab.")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_tok = sub.add_parser("count", help="Count tokens in text.")
    p_tok.add_argument("text")

    p_cost = sub.add_parser("cost", help="Estimate cost for token counts.")
    p_cost.add_argument("--in-tokens", type=int, required=True)
    p_cost.add_argument("--out-tokens", type=int, required=True)
    p_cost.add_argument("--in-price", type=float, required=True, help="$ / 1K input tokens")
    p_cost.add_argument("--out-price", type=float, required=True, help="$ / 1K output tokens")

    p_sim = sub.add_parser("sim", help="Cosine similarity of two strings.")
    p_sim.add_argument("a")
    p_sim.add_argument("b")

    args = parser.parse_args(argv)

    if args.cmd == "count":
        print(f"{count_tokens(args.text)} tokens")
    elif args.cmd == "cost":
        price = ModelPrice(args.in_price, args.out_price)
        total = estimate_cost(args.in_tokens, args.out_tokens, price)
        print(f"${total:.6f}")
    elif args.cmd == "sim":
        print(f"cosine similarity: {similarity(args.a, args.b):.4f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
