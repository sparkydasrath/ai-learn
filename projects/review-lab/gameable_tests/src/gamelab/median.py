def median(xs: list[float]) -> float:
    if not xs:
        raise ValueError("median() arg is an empty sequence")

    ordered = sorted(xs)
    middle = len(ordered) // 2

    if len(ordered) % 2 == 0:
        return (ordered[middle - 1] + ordered[middle]) / 2

    return ordered[middle]
