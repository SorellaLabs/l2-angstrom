from random import randint, seed as seed_random
import sys


def do_full_precision_newton(y: int, x: int) -> int:
    '''
    Calculates `sqrt(y / x) * 2**96` in full precision
    '''
    if (y * 2**192) // x == 0:
        return 0

    g = 1  # guess
    while True:
        new_g = (g * g * x + y * (2**96)**2) // (2 * x * g)
        if new_g == g:
            return new_g
        g = new_g


y, x = map(int, sys.argv[1:])
result = do_full_precision_newton(y, x)
print(result.to_bytes(32, 'big').hex())
