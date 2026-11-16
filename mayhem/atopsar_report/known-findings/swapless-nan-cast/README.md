# atopsar: NaN cast to unsigned on a host without swap (memline)

Reproduce (with `-fsanitize=float-cast-overflow`, which build.sh relaxes for the fuzz build):
`atopsar -r ../testsuite/sample-2.13.raw -A` on any log recorded on a host with no swap.

    atopsar.c:1577:21: runtime error: -nan is outside the range of representable values
    of type 'unsigned int'

`memline()` computes `((totswap - freeswap) * 100.0 / totswap) * 100 / swpbadness`;
with `totswap == 0` this is 0/0 = NaN, converted to `unsigned int sbadness` (UB; on x86
it yields 0x80000000-style garbage, so the "critical" marker can be set spuriously).
Fix: `sbadness = ss->mem.totswap ? ... : 0;` (same guard for `physmem` in `mbadness`).

Because every swapless log hits it before any report is printed, the fuzz build relaxes
only `float-cast-overflow` (`mayhem/build.sh`); all other UBSan checks and ASan stay halting.
