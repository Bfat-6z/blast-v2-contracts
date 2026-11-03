# Blast timelock

A value behind a timelock. `Timelocked<T>` holds a value that changes only
through `schedule`, and every scheduled change takes effect exactly the
timelock's delay after it was scheduled. The positive `u64` delay is fixed when
the value is created, so no caller can ask for a shorter one later.

```move
// Store a timelocked value in your own object; every change waits seven days.
let mut share = blast_fun_timelock::new(2_500u64, 7 * 24 * 60 * 60 * 1_000);

// Schedule a change: the current value stays in force for the whole delay.
share.schedule(1_000, &clock);

// Read the value in force now, and what is pending and when.
let in_force = share.value(&clock);
let (pending, at_ms) = (share.scheduled(), share.scheduled_at_ms());
```

A new schedule replaces a pending one and restarts the delay, so scheduling the
value already in force cancels a pending change. Nothing scheduled ever takes
effect sooner than the delay after it was last scheduled. A new value is in force
at once; to delay the first value too, create it with a default and schedule the
real one:

```move
let mut share = blast_fun_timelock::new(0u64, delay_ms);
share.schedule(2_500, &clock);
```

There is no policy ceiling on the delay. `schedule` aborts if the current clock
timestamp plus the configured delay would overflow `u64`.

A `Timelocked` has `copy`, so a copy is an independent value: always schedule
the field stored in your object.

The package holds no objects and needs no administrator: the module that stores
a `Timelocked` decides who may schedule it, and the guarantee holds as long as
that module changes the value only through `schedule`. A `&mut Timelocked` can
also replace the whole value, delay included, so never hand one out. It depends only on the
Sui framework. Use `scripts/check_coverage.sh` for the package coverage gate.

## Mainnet

Published at
`0x1749b76a3ae065dedfe847578b07826fa83d1e18ff485d9e4f9647f3698e104d` and made
immutable in the same transaction,
[`FQhZPuNDEzBENZhvRuCW5oYme9KAeYKZtnaGBF2yR7oZ`](https://suiscan.xyz/mainnet/tx/FQhZPuNDEzBENZhvRuCW5oYme9KAeYKZtnaGBF2yR7oZ):
`Publish`, then `0x2::package::make_immutable(Result(0))`. No `UpgradeCap`
exists, so no one can change the code. See the
[deployment record](../../deployments/sui/mainnet/2026-09-26-timelock-unbounded-delay.json).

The earlier package at
`0x7e17a8d6c068ccdfb7e8a0c222da363d9c9dcf9fcda97befa3352a7b54ff2f29`
is superseded because it limited delays to ten years.
