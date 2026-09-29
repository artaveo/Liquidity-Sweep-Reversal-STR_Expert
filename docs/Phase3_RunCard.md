# Phase 3 Run Card — Pre-Implementation Event Study

Phase 3 adds the event study to `LSR_Expert`. The EA still never trades. The Phase 1 and Phase 2 Run Cards still apply.

## 1. Tests

- **MQL5:** run `Scripts\LiquiditySweepReversal\LSR_Tests`. The result must be `RESULT: PASS ... failed=0`.
- **Python** (from `python/`):

  ```
  python -m unittest discover -s tests -v
  ```

## 2. Strategy Tester

Use the same tester settings as Phases 1 and 2: XAUUSD, **Every tick based on real ticks**, **2026.01.01 → 2026.07.01**, deposit 100000 USD. Keep every input at its default; the default `ExperimentId` is `LSR-P3-EVENTSTUDY`.

Phase 3 inputs:

| Input | Default |
|---|---|
| EventStudyEnabled | `true` |
| SweepSLExtraPips | `3.0` |
| SingleTP_R | `2.0` |
| NewsMode | `OBSERVE_ONLY` (no validated calendar) |

## 3. Analysis (from `python/`)

```
python -m lsr_reference.run_reference "<Common>\Files\LSR\LSR-P3-EVENTSTUDY"
python -m lsr_reference.event_study  "<Common>\Files\LSR\LSR-P3-EVENTSTUDY"
```

The first command re-checks the Phase 2 ledgers, which must be byte-identical. The second writes `python_reference/event_study_report.md` and `event_study_report.json`. For each timeframe and each hypothesis they give the event count, independent days, mean EventStudyNetR, one-sided 95% upper bound, costs, MAE/MFE, the reversal/continuation table, stratifications, and the timeframe's early-stop classification (3.6).

## 4. Output — `event_study_<TF>.csv`

There is one row per SETUP event and hypothesis. Each row records:
- the event itself: source tags, level IDs, touches, prominence, sweep OHLC, penetration and reclaim;
- entry: tick time and delay, Bid/Ask, spread;
- SL/TP and PlannedRisk1R;
- exit: quote, reason, gap and ambiguity flags;
- swap, gross/net P/L and R;
- MAE/MFE;
- forward returns and classes at 1, 3, 5, 10 and 20 bars;
- time, weekday and spread buckets, news state and the quarantine flag.

## 5. Phase 3 Gate

- [ ] Both hypotheses reported for every timeframe, with the exact inputs (none non-default)
- [ ] Data gate `DATA-PASSED`
- [ ] Early-stop classification recorded per timeframe, plus the project classification
- [ ] No 2025 data used; the range never extends beyond the rapid sample
