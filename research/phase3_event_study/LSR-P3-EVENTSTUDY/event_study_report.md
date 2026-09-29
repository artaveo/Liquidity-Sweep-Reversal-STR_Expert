# Phase 3 Event Study Report

Experiment `LSR-P3-EVENTSTUDY` · data gate **DATA-PASSED** · non-default inputs: []

EventStudyNetR = RealizedNetPnL / PlannedRisk1R (1 lot, LIVE_NATIVE_STOP, net 2R target, no BE, no re-entry). One-sided 95% upper bound from a day-block bootstrap. Timeframes are never pooled.

| TF | Hypothesis | Events | Days | Mean NetR | Upper95 | Win rate | Mean costs R | TP / STOP | Early stop |
|---|---|---|---|---|---|---|---|---|---|
| M5 | A_RECLAIM_CONTROL | 3273 | 127 | -0.182 | -0.143 | 0.279 | 0.020 | 914 / 2359 | STOP_EARLY_REDESIGN |
| M5 | B_NEXT_BAR_CONFIRM | 651 | 126 | -0.093 | -0.003 | 0.307 | 0.012 | 200 / 451 | STOP_EARLY_REDESIGN |
| M15 | A_RECLAIM_CONTROL | 1090 | 127 | -0.056 | 0.020 | 0.320 | 0.014 | 349 / 741 | CONTINUE |
| M15 | B_NEXT_BAR_CONFIRM | 211 | 103 | -0.032 | 0.132 | 0.332 | 0.011 | 70 / 141 | CONTINUE |
| H1 | A_RECLAIM_CONTROL | 282 | 113 | -0.110 | 0.016 | 0.305 | 0.013 | 86 / 196 | INCONCLUSIVE |
| H1 | B_NEXT_BAR_CONFIRM | 54 | 46 | 0.359 | 0.706 | 0.444 | 0.014 | 24 / 30 | INCONCLUSIVE |

**Project classification: CONTINUE**

## Reversal vs continuation (per SETUP event)

| TF | H | Reversal | Continuation | Unresolved | Reversal share |
|---|---|---|---|---|---|
| M5 | 1 | 1896 | 1780 | 4 | 0.515 |
| M5 | 3 | 1922 | 1754 | 4 | 0.522 |
| M5 | 5 | 1905 | 1773 | 2 | 0.518 |
| M5 | 10 | 1909 | 1770 | 1 | 0.519 |
| M5 | 20 | 1928 | 1752 | 0 | 0.524 |
| M15 | 1 | 641 | 569 | 0 | 0.530 |
| M15 | 3 | 651 | 559 | 0 | 0.538 |
| M15 | 5 | 643 | 567 | 0 | 0.531 |
| M15 | 10 | 661 | 548 | 1 | 0.546 |
| M15 | 20 | 627 | 581 | 1 | 0.519 |
| H1 | 1 | 161 | 155 | 0 | 0.509 |
| H1 | 3 | 178 | 138 | 0 | 0.563 |
| H1 | 5 | 166 | 150 | 0 | 0.525 |
| H1 | 10 | 161 | 154 | 0 | 0.511 |
| H1 | 20 | 156 | 157 | 0 | 0.498 |
