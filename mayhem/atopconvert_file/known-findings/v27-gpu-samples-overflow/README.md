# atopconvert: signed overflow converting a 2.7 log (2.12 -> 2.13 GPU step)

Reproduce: `/mayhem/mayhem/build/bin/atopconvert sample-2.7.1.raw out.raw`

`sample-2.7.1.raw` is an ordinary log written by atop v2.7.1 (`atop -w f 1 2`, no GPUs).
Converting it to 2.13 aborts under UBSan:

    atopconvert.c:693:20: runtime error: signed integer overflow:
    1661468704 * 7956019342284947488 cannot be represented in type 'count_t'

The 2.12 -> 2.13 per-task GPU converter multiplies `gpubusycum/membusycum` by `samples`
("oneshot counter to cumulative"); for a log that went through the older steps, those
fields hold values that were never GPU counters, so the product overflows (UB). Impact:
wrong (garbage) GPU counters in converted logs; UB in the converter. Fix: only scale when
the task actually had GPU stats (e.g. `gpulist`/`nrgpus` non-zero) and saturate the product.

Kept out of `testsuite/` because a seed that crashes is replayed on every run.
