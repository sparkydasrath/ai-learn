from gamelab.median import median

def test_median() -> None:
    assert median([1,3,2]) == 2
    assert median([4,1,3,2]) == 2.5