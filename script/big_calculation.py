liquidity = 2000000000000000000000
priceLowerSqrtX96 = 79267784519130042428790663799
compensationAmount0 = 4655000000000000
sumUpToThisRange0 = 4998500349930012597
sumUpToThisRange1 = 5001000100005000100
rangeVirtualReserves0 = 1999000299930013997480
rangeVirtualReserves1 = 2001000200020001000020


def sqrt(v: int) -> int:
    assert v >= 0, f'negative v: {v}'
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


def t(s, x):
    if x >= 1 << 256:
        print(s)
    return x


u = sumUpToThisRange0+rangeVirtualReserves0-compensationAmount0
d = sqrt(2**192 * (sumUpToThisRange1 * u - rangeVirtualReserves1 *
         (sumUpToThisRange0 - compensationAmount0)))
a = (liquidity * 2**96 + d)//u
b = (liquidity * 2**96 - d)//u

print(a)
print(b)
