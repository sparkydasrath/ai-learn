from token_lab.cost import ModelPrice, estimate_cost


def test_estimate_cost_sums_input_and_output() -> None:
    price = ModelPrice(input_per_1k=0.50, output_per_1k=1.50)
    # 2,000 input @ $0.50/1k = $1.00 ; 1,000 output @ $1.50/1k = $1.50
    assert estimate_cost(2000, 1000, price) == 2.50


def test_estimate_cost_zero() -> None:
    assert estimate_cost(0, 0, ModelPrice(1.0, 2.0)) == 0.0
