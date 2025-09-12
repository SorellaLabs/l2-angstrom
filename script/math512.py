import sys

func = sys.argv[1]

RESULT_OK_BYTE = b"\x00"
RESULT_FAILED_BYTE = b"\x01"


def okay(*args):
    print('0x' + (RESULT_OK_BYTE +
          b''.join([arg.to_bytes(32, "big") for arg in args])).hex())
    sys.exit(0)


def failed():
    print('0x' + (RESULT_FAILED_BYTE).hex())
    sys.exit(1)


def int_sqrt(x):
    if x == 0:
        return 0
    root = x
    last = root + 1
    while root < last:
        last = root
        root = (root + x // root) // 2

    if not (last ** 2 <= x and x < (last + 1) ** 2):
        print(f"invalid root: 0x{root:x}", file=sys.stderr)
        failed()

    return last


def main():
    func = sys.argv[1]
    if func == "div512by256":
        x1 = int(sys.argv[2])
        x0 = int(sys.argv[3])
        d = int(sys.argv[4])
        x = x1 * (2**256) + x0
        y = x // d
        y1, y0 = divmod(y, 2**256)
        okay(y1, y0)
    elif func == "sqrt512":
        x1, x0 = map(int, sys.argv[2:4])
        x = x1 * (2**256) + x0
        okay(int_sqrt(x))
    else:
        failed()


try:
    main()
except Exception as e:
    print('0x' + (RESULT_FAILED_BYTE).hex())
    raise e
