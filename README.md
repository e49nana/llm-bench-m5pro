# Local LLM Benchmarks — MacBook Pro M5 Pro

## Hardware
- Apple M5 Pro, 48 GB unified memory, 307 GB/s memory bandwidth
- Metal reports `recommendedMaxWorkingSetSize` = 40200.90 MB (~82% available to GPU)
- GPU family Apple10 / Metal4, bfloat and tensor acceleration enabled

## Setup
- llama.cpp build b10159 (commit `f95de9776`), built from source with `-DGGML_METAL=ON`
- Model: `ggml-org/gemma-3-1b-it-GGUF`, Q4_K_M — 762.49 MiB, 1.0B params

## Results

| Test | Value |
|---|---|
| tg128 (generation) | 105–108 t/s, ±2–3% |
| pp512 (prompt, peak) | ~9970 t/s |
| pp512 (prompt, sustained) | ~6100 t/s |

Prefill/generation ratio: ~58x sustained. Prefill is compute-bound and
parallel; generation is memory-bound and sequential.

## Bandwidth efficiency
Theoretical generation ceiling: 307 GB/s ÷ 0.80 GB = 384 t/s.
Measured: 105 t/s — 27% of theoretical.
At this model size the workload is not bandwidth-bound. Per-token fixed
costs (kernel dispatch, sampling) dominate. Expect efficiency to rise
with model size.

## Investigation: pp512 variance

`llama-bench` pp512 results depended on the `-r` flag:

| -r | mean t/s | stddev |
|---|---|---|
| 3 | 9540 | 7% |
| 5 | 8344 | 15% |
| 10 | 6677 | 34% |
| 30 | 6108 | 22% |

**H1 — thermal throttling.** Refuted. Three back-to-back `-r 3` runs gave
9542 / 9552 / 9524. No decay between invocations.

**H2 — tg128 in the same invocation.** Refuted. `-r 10` with and without
tg128 gave 6564 and 6677 (1.7% apart).

**H3 — KV cache growth across repetitions.** Refuted. Raw per-repetition
samples are not monotonic.

**H4 — fast DVFS / power governor.** Supported. Raw samples from `-r 30`
(`-o json`) show a damped oscillation converging on ~6100 t/s:

```
rep 1:      9968   boost clocks
rep 8:      4080   undershoot
rep 15:     6417   overshoot
rep 21:     5190
reps 26-30: 6100-6175   settled
```

Oscillation period ≈ 1.2 s. Full 30-rep run: 2.6 s. The control loop
resets between process invocations, which is why short runs always
start at boost clocks.

**Takeaway:** a single pp512 figure is meaningless unless you state where
on this curve it was taken. Published peak numbers are artifacts of
short measurement windows.

## Method note
An earlier comparison changed three variables simultaneously (`-r`,
presence of tg128, chronological order) and was not interpretable.
Isolating one variable per experiment was required to get an answer.
