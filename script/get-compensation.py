from dataclasses import dataclass
from decimal import getcontext, Decimal as D
import sys
from typing import Callable
from collections.abc import Generator


def emit_error(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def from_solidity_int(x: int) -> int:
    if x >= 1 << 255:
        return x - (1 << 256)
    return x


@dataclass(frozen=True)
class Position:
    tick_lower: int
    tick_upper: int
    liquidity: int


def read_word(data: bytes, offset: int) -> int:
    return int.from_bytes(data[offset:offset+32], "big")


def decode_position(raw_position: bytes) -> Position:
    assert len(raw_position) == 96, "Position must be 96 bytes"
    tick_lower = read_word(raw_position, 0)
    tick_upper = read_word(raw_position, 32)
    liquidity = read_word(raw_position, 64)
    return Position(
        tick_lower=from_solidity_int(tick_lower),
        tick_upper=from_solidity_int(tick_upper),
        liquidity=liquidity
    )


POSITION_ENCODED_LENGTH = 96


def decode_positions(raw_positions: bytes) -> list[Position]:
    positions_rel_offset = read_word(raw_positions, 0x00)
    positions_length = read_word(raw_positions, 0x20)
    position_bytes = raw_positions[0x40:]
    total_positions = len(position_bytes) // POSITION_ENCODED_LENGTH
    assert positions_rel_offset == 0x20 and positions_length == total_positions, "invalid position encoding"

    assert len(position_bytes) % POSITION_ENCODED_LENGTH == 0, \
        "Positions must be a multiple of 96 bytes"
    return [decode_position(position_bytes[i:i+POSITION_ENCODED_LENGTH]) for i in range(0, len(position_bytes), POSITION_ENCODED_LENGTH)]


def tick_to_sqrt_price(tick: int) -> D:
    return (D('1.0001') ** D(tick)).sqrt()


def from_X96(x: int) -> D:
    return D(x) / (1 << 96)


def delta_x(sqrt_price_lower: D, sqrt_price_upper: D, liquidity: int) -> D:
    dx = liquidity * (1/sqrt_price_lower - 1/sqrt_price_upper)
    assert dx >= 0, "dx negative"
    return dx


def delta_y(sqrt_price_lower: D, sqrt_price_upper: D, liquidity: int) -> D:
    dy = liquidity * (sqrt_price_upper - sqrt_price_lower)
    assert dy >= 0, "dy negative"
    return dy


@dataclass(frozen=True)
class PricedTick:
    tick: int
    sqrt_price: D


def get_ticks_zero_for_one(
    start_upper: PricedTick,
    end_lower: PricedTick,
    sorted_ticks: list[int],
) -> Generator[PricedTick, None, None]:
    yield start_upper
    for tick in reversed(sorted_ticks):
        sqrt_price = tick_to_sqrt_price(tick)
        if end_lower.sqrt_price <= sqrt_price <= start_upper.sqrt_price:
            yield PricedTick(tick, sqrt_price)
    yield end_lower


def get_ticks_one_for_zero(
    start_lower: PricedTick,
    end_upper: PricedTick,
    sorted_ticks: list[int],
) -> Generator[PricedTick, None, None]:
    yield start_lower
    for tick in sorted_ticks:
        next_sqrt_price = tick_to_sqrt_price(tick)
        if start_lower.sqrt_price <= next_sqrt_price <= end_upper.sqrt_price:
            yield PricedTick(tick, next_sqrt_price)
    yield end_upper


def ticks_iter_to_ranges(ticks_iter: Callable[[], Generator[PricedTick, None, None]]) -> Generator[tuple[PricedTick, PricedTick], None, None]:
    last_iter = ticks_iter()
    next_iter = ticks_iter()
    _ = next(next_iter)

    for last_tick, next_tick in zip(last_iter, next_iter):
        yield (last_tick, next_tick)


@dataclass
class TickState:
    sorted_ticks: list[int]
    ticks_to_liquidity: dict[int, int]

    def get_range_lower(self, tick: int) -> int | None:
        for init_lower, init_upper in zip(self.sorted_ticks, self.sorted_ticks[1:]):
            if init_lower <= tick < init_upper:
                return init_lower
        return None

    def get_liquidity(self, tick: int) -> int:
        if (lower := self.get_range_lower(tick)) is not None:
            return self.ticks_to_liquidity[lower]
        return 0

    @classmethod
    def from_positions(cls, positions: list[Position]) -> "TickState":
        initialized_ticks: set[int] = set()
        for position in positions:
            initialized_ticks.add(position.tick_lower)
            initialized_ticks.add(position.tick_upper)
        sorted_ticks = sorted(initialized_ticks)
        ticks_to_liquidity = {tick: 0 for tick in initialized_ticks}
        for position in positions:
            for tick in initialized_ticks:
                if position.tick_lower <= tick < position.tick_upper:
                    ticks_to_liquidity[tick] += position.liquidity
        return cls(sorted_ticks, ticks_to_liquidity)

    def get_ranges_zero_for_one(self, start_upper: PricedTick, end_lower: PricedTick) -> Generator[tuple[PricedTick, PricedTick], None, None]:
        assert start_upper.tick >= end_lower.tick, "start_upper.tick < end_lower.tick"
        assert start_upper.sqrt_price >= end_lower.sqrt_price, "start_upper.sqrt_price < end_lower.sqrt_price"
        return ticks_iter_to_ranges(lambda: get_ticks_zero_for_one(start_upper, end_lower, self.sorted_ticks))

    def get_ranges_one_for_zero(self, start_lower: PricedTick, end_upper: PricedTick) -> Generator[tuple[PricedTick, PricedTick], None, None]:
        assert start_lower.tick <= end_upper.tick, "start_lower.tick > end_upper.tick"
        assert start_lower.sqrt_price <= end_upper.sqrt_price, "start_lower.sqrt_price > end_upper.sqrt_price"
        return ticks_iter_to_ranges(lambda: get_ticks_one_for_zero(start_lower, end_upper, self.sorted_ticks))

    def get_zero_for_one_compensation_amount(
        self,
        start_upper: PricedTick,
        end_lower: PricedTick,
        compensation_price: D,
    ) -> Generator[tuple[PricedTick, PricedTick, D], None, None]:
        print(f"\nZero-for-One Compensation Amount", file=sys.stderr)
        pstar_sqrt = compensation_price.sqrt()
        print(f"pstar_sqrt: {pstar_sqrt:.6f}", file=sys.stderr)
        for upper, lower in self.get_ranges_zero_for_one(start_upper, end_lower):
            liquidity = self.get_liquidity(lower.tick)
            print(
                f"{upper.sqrt_price:.6f} -> {lower.sqrt_price:.6f} ({upper.tick:3} -> {lower.tick:3}) [{liquidity/10**18:.6f}]", file=sys.stderr)
            if pstar_sqrt >= upper.sqrt_price:
                break
            if liquidity == 0:
                range_comp = D(0)
            else:
                dx = delta_x(
                    max(lower.sqrt_price, pstar_sqrt),
                    upper.sqrt_price,
                    liquidity
                )
                dy = delta_y(
                    max(lower.sqrt_price, pstar_sqrt),
                    upper.sqrt_price,
                    liquidity
                )
                print(f"  dx: {dx/10**18:.6f}", file=sys.stderr)
                print(f"  dy: {dy/10**18:.6f}", file=sys.stderr)
                range_comp = dy / compensation_price - dx
                print(
                    f"  range_comp: {range_comp/10**18:.6f}", file=sys.stderr)

            assert range_comp >= 0, "range_comp negative"
            yield (lower, upper, range_comp)

    def get_one_for_zero_compensation_amount(self, start_lower: PricedTick, end_upper: PricedTick, compensation_price: D) -> Generator[tuple[PricedTick, PricedTick, D], None, None]:
        for lower, upper in self.get_ranges_one_for_zero(start_lower, end_upper):
            liquidity = self.get_liquidity(lower.tick)
            dx = delta_x(lower.sqrt_price, upper.sqrt_price, liquidity)
            dy = delta_y(lower.sqrt_price, upper.sqrt_price, liquidity)
            range_comp = dx - dy / compensation_price
            assert range_comp >= 0, "range_comp negative"
            yield (lower, upper, range_comp)

    def get_reward_share(self, position: Position, rewards: dict[int, D]) -> D:
        total_reward = D(0)
        for tick, reward in rewards.items():
            if position.tick_lower <= tick < position.tick_upper:
                total_reward += reward * position.liquidity / \
                    self.get_liquidity(tick)
        return total_reward


def distribute_rewards_ranges(
    direction_zero_for_one: bool,
    tick_state: TickState,
    start: PricedTick,
    end: PricedTick,
    total_compensation_amount: int,
) -> tuple[D, dict[int, D]]:
    compensation_price = compute_and_verify_compensation_price(
        direction_zero_for_one,
        tick_state,
        start,
        end,
        total_compensation_amount
    )
    print("Reward Ranges:", file=sys.stderr)
    rewards = {tick: D(0) for tick in tick_state.sorted_ticks}
    if direction_zero_for_one:
        for lower, _, range_comp in tick_state.get_zero_for_one_compensation_amount(start, end, compensation_price):
            initialized_tick = tick_state.get_range_lower(lower.tick)
            assert initialized_tick is not None or range_comp == 0, "initialized_tick is None and range_comp is not 0"
            if initialized_tick is not None:
                rewards[initialized_tick] += range_comp
    else:
        for lower, _, range_comp in tick_state.get_one_for_zero_compensation_amount(start, end, compensation_price):
            initialized_tick = tick_state.get_range_lower(lower.tick)
            assert initialized_tick is not None or range_comp == 0, "initialized_tick is None and range_comp is not 0"
            if initialized_tick is not None:
                rewards[initialized_tick] += range_comp
    return compensation_price, rewards


def compute_and_verify_compensation_price(
    direction_zero_for_one: bool,
    tick_state: TickState,
    start: PricedTick,
    end: PricedTick,
    total_compensation_amount: int,
) -> D:
    compensation_price = compute_compensation_price(
        direction_zero_for_one, tick_state, start, end, total_compensation_amount)

    total_compensation_distributed = D(0)
    if direction_zero_for_one:
        for _, _, range_comp in tick_state.get_zero_for_one_compensation_amount(start, end, compensation_price):
            total_compensation_distributed += range_comp
    else:
        for _, _, range_comp in tick_state.get_one_for_zero_compensation_amount(start, end, compensation_price):
            total_compensation_distributed += range_comp

    assert quasi_eq(total_compensation_distributed, D(total_compensation_amount)), \
        f"Total compensation distributed is not equal to total compensation amount ({total_compensation_distributed} != {total_compensation_amount})"

    return compensation_price


def quasi_eq(a: D, b: D) -> bool:
    return abs(a - b) < D('1e-10')


def compute_compensation_price(
    direction_zero_for_one: bool,
    tick_state: TickState,
    start: PricedTick,
    end: PricedTick,
    total_compensation_amount: int,
) -> D:

    sum_x = D(0)
    sum_y = D(0)

    if direction_zero_for_one:
        for upper, lower in tick_state.get_ranges_zero_for_one(start, end):
            liquidity = tick_state.get_liquidity(lower.tick)
            dx = delta_x(lower.sqrt_price, upper.sqrt_price, liquidity)
            dy = delta_y(lower.sqrt_price, upper.sqrt_price, liquidity)
            pstar_guess_sqrt = (
                (sum_y + dy) / (sum_x + dx + total_compensation_amount)
            ).sqrt()

            # within range
            if pstar_guess_sqrt >= lower.sqrt_price:
                virtual_x: D = D(liquidity) / upper.sqrt_price
                virtual_y: D = D(liquidity) * upper.sqrt_price
                a = total_compensation_amount + sum_x - virtual_x
                det = D(liquidity)**2 + a * (sum_y + virtual_y)
                pstar_sqrt = (-D(liquidity) + det.sqrt()) / a
                return pstar_sqrt**2
            sum_x += dx
            sum_y += dy
        return sum_y / (sum_x + total_compensation_amount)
    else:
        for lower, upper in tick_state.get_ranges_one_for_zero(start, end):
            liquidity = tick_state.get_liquidity(lower.tick)
            dx = delta_x(lower.sqrt_price, upper.sqrt_price, liquidity)
            dy = delta_y(lower.sqrt_price, upper.sqrt_price, liquidity)

            # within range
            if (net_x := sum_x + dx - total_compensation_amount) >= 0\
                    and (pstar_guess_sqrt := ((sum_y + dy) / net_x).sqrt()) <= upper.sqrt_price:
                virtual_x: D = D(liquidity) * lower.sqrt_price
                virtual_y: D = D(liquidity) / lower.sqrt_price
                a = sum_x + virtual_x - total_compensation_amount
                det = D(liquidity)**2 + a * (sum_y - virtual_y)
                pstar_sqrt = (D(liquidity) + det.sqrt()) / a
                return pstar_sqrt**2
            sum_x += dx
            sum_y += dy
        pstar = sum_y / (sum_x - total_compensation_amount)
        assert pstar >= 0, "pstar negative"
        return pstar


def main():
    getcontext().prec = 40

    if len(sys.argv) != 8:
        emit_error("Usage: python get-compensation.py <direction> <positions> <start_sqrt_price> <end_sqrt_price> <start_tick> <end_tick> <compensation_amount>")

    direction_zero_for_one = {
        "zero_for_one": True,
        "one_for_zero": False,
    }[sys.argv[1]]

    raw_positions = bytes.fromhex(sys.argv[2].removeprefix("0x"))
    positions = decode_positions(raw_positions)

    start_sqrt_price = from_X96(int(sys.argv[3]))
    end_sqrt_price = from_X96(int(sys.argv[4]))
    start_tick = int(sys.argv[5])
    end_tick = int(sys.argv[6])
    total_compensation_amount = int(sys.argv[7])

    start = PricedTick(start_tick, start_sqrt_price)
    end = PricedTick(end_tick, end_sqrt_price)
    tick_state = TickState.from_positions(positions)
    print(f"direction_zero_for_one: {direction_zero_for_one}", file=sys.stderr)
    print(
        f"total_compensation_amount: {total_compensation_amount / 10**18:.6f}", file=sys.stderr)
    compensation_price, tick_rewards = distribute_rewards_ranges(
        direction_zero_for_one, tick_state, start, end, total_compensation_amount
    )
    print(f'tick_rewards: {tick_rewards}', file=sys.stderr)

    position_rewards = [
        round(tick_state.get_reward_share(position, tick_rewards)) for position in positions
    ]
    print("Positions:", file=sys.stderr)

    for position, reward in zip(positions, position_rewards):
        print(
            f"  [{position.tick_lower:3}, {position.tick_upper:3}] {position.liquidity/1e18:10,.2f} {reward/1e18:10,.6f}",
            file=sys.stderr
        )

    print(f"position_rewards: {position_rewards}", file=sys.stderr)
    print(f"pstar sqrt: {compensation_price.sqrt()}", file=sys.stderr)

    pstar_sqrt_X96 = round(compensation_price.sqrt() * 2**96)

    encoded_out = pstar_sqrt_X96.to_bytes(32, "big")\
        + int(0x40).to_bytes(32, "big")\
        + len(position_rewards).to_bytes(32, "big")\
        + b"".join(rewards.to_bytes(32, "big") for rewards in position_rewards)
    print(f"0x{encoded_out.hex()}")


if __name__ == "__main__":
    main()
