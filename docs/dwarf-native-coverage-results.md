# DWARF/native coverage results

Status on 2026-10-03: **direct-read helper deferred**. See
[`dwarf-native-coverage.md`](dwarf-native-coverage.md) for the observed OTP
layout, the pointer-lifetime problem, and the reproducible continuation setup.

| Check | Result |
| --- | --- |
| OTP native coverage public API | PASS on a small line-coverage fixture and the experimental `otp_native_public` backend |
| DWARF type/field discovery | PASS for the investigated OTP 27.0 binary |
| Safe direct coverage read | NOT RUN — no proven code-loader lifetime contract/helper |
| Direct read versus `code:get_coverage/2` | NOT RUN |
| OTP-public Cowboy smoke (30 s) | PASS after fixing corpus metadata shape: 5889 executions, 196.26 exec/s, 0 infrastructure errors on final code; one final-code run only |
| DWARF-native Cowboy smoke (30 s) | NOT RUN — backend not implemented |
| Native reset/read/novelty/merge microbenchmark | PASS; see `docs/performance/otp-native-public-2026-10-03.term` and `otp-native-public-cowboy-2026-10-03.term` |
| 15-minute Cowboy runs | NOT RUN; reserved for manual execution after smokes |

On the fixed Cowboy GET path, component medians were: reset 0.50 µs,
`code:get_coverage` 5.63 µs, compact conversion 30.77 µs, no-novelty scan
3.37 µs, merge 4.97 µs, full direct-target cycle 68.68 µs (10 samples of
100 iterations after two warmups). The 30-second full EFZ run averages about
5.1 ms per execution, so neither `get_coverage` nor conversion is presently
shown to dominate end-to-end EFZ time. A direct helper is not justified by
these measurements alone. There are **no** DWARF-native performance numbers.
