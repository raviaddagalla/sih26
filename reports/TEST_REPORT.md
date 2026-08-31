# IDR Project Verification Report

## VERDICT: **FAIL** (Target: < 10% Median Drift)

**Generated At:** 2026-08-31T12:29:12.135304+00:00
**Ensemble Model Checkpoint SHA256:** `a1c03828b0bf997aacde7494334d5b0f13e2495d398d29a58ea3aacd36fd88ca`
**Manifest SHA256:** `1b0c4e9092c7ef73f40926ea7e5412a3b5497694e48e100d37b890dd424ab1b1`
**Benchmark Core SHA256:** `886becbc736b168f9f2adaa84d72efc9a846d74fd680d0884a8bd18d451559eb`

---

## 1. Multi-Window Drift Benchmark Results
Tested over seeds [42, 123, 2024].
Excluded windows (path < 300m): 31

| Trip | Window | Valid Count | Low-Motion Count | Median EKF Drift (%) | Mean EKF Drift (%) | Median Final Error (m) |
|---|---|---|---|---|---|---|
| A5 | 30s | 35 | 0 | **17.41%** | 18.89% | 105.40m |
| A5 | 60s | 35 | 0 | **30.98%** | 51.80% | 333.47m |
| A5 | 90s | 42 | 0 | **43.40%** | 89.79% | 702.60m |
| T2 | 30s | 42 | 0 | **20.84%** | 25.90% | 151.52m |
| T2 | 60s | 41 | 0 | **27.48%** | 29.28% | 441.55m |
| T2 | 90s | 44 | 0 | **25.66%** | 29.07% | 729.20m |

## 2. Ablation Comparison

| Model | Test RMSE (km/h) | Median Drift (%) | Mean Drift (%) |
|---|---|---|---|
| Baseline | 40.65 | 37.76 | 37.68 |
| + ZUPT | 36.40 | 30.11 | 32.53 |
| + Domain Aug | 55.90 | 29.06 | 33.01 |


## 3. Unit Tests
All core mathematical integrators, GPS crosschecks, and evaluation gating assertions passed (`pytest tests/`).