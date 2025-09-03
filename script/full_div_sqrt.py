from random import randint, seed as seed_random
import sys


def do_full_precision_newton(y: int, x: int) -> int:
    '''
    Calculates `sqrt(y / x) * 2**96` in full precision
    '''
    v = (y * (2**96)**2) // x
    if v == 0:
        return 0

    g = (1 << 256) - 1  # guess
    i = 0
    while True:
        new_g = (g + v // g) // 2
        # print(f'{i:>3}: {g} -> {new_g}', file=sys.stderr)

        if new_g >= g:
            return min(new_g, g)
        i += 1
        if i > 10000:
            raise Exception(f"no convergence after {i} rounds ({g}, {new_g})")
        g = new_g


y, x = map(int, sys.argv[1:])
result = do_full_precision_newton(y, x)
print(result.to_bytes(32, 'big').hex())
