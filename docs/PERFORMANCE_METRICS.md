# Performance Metrics and Evaluation Rules

**Reviewed:** 2026-10-10. Rules are specified before strategy/backtest implementation. No performance data is available in Phase 1; mock ideas do not count as observations.

## Unit of evaluation and immutable plan

One **recommendation version** is the evaluation unit. At creation time preserve the symbol/security identity, created-at time, data timestamps/source/coverage, strategy and prompt versions, horizon, entry range `[entryLow, entryHigh]`, entry-valid-until time, stop, target, expected holding horizon, planned share count/allocation, fees/slippage assumptions, evidence, and the exact signal available at that time. Later edits or analysis create a new version; never rewrite the original plan.

An idea is **actionable** only if it passed hard risk/data checks and had an entry/stop/target and a non-empty validity window before future observations were known. Exclude explicit no-trade decisions from actionable win-rate denominator, but report no-trade count/rate and the number of excluded or invalidated ideas. Saved-only, favorable-only or user-accepted-only samples must not be substituted for all generated actionable recommendations.

## Entry and simulated execution rules

1. An entry is triggered only by eligible price observations during the predeclared validity window. Store trigger time and the observation source/venue/delay. A daily low touching the range does not prove a fill at that low.
2. With sufficiently granular quote/trade data, simulate a marketable limit/limit order using available bid/ask/volume and the predefined price/size assumptions. Without depth/quotes, use a conservative next eligible bar/open and documented spread/slippage; do not assume the intraday low or perfect limit fill.
3. If price opens/gaps above the permitted entry, classify as missed/gap-through rather than filling at the planned price. If price never reaches the entry before expiry, classify **Unfilled**.
4. Do not evaluate stop/target performance for an unfilled idea as if a position existed. Unfilled remains in entry-trigger statistics and overall opportunity reporting.
5. If a bar crosses both stop and target and the order is unknown, use higher-resolution data if available; otherwise assume stop occurred first. Apply conservative execution beyond stop for gaps.
6. Exits include stated stop, stated target, horizon expiry/defined time exit, or documented invalidation event. Include commissions/fees when applicable, spread, slippage, and any required transaction costs; if a cost is unknown, state the assumption and run sensitivity analysis.

## Required measures

### Profitable trade-plan success rate (primary 85% goal)

`profitable trade-plan success rate = matured actionable recommendations with a realistic entry and positive net realized simulated P&L / matured actionable recommendations with a realistic entry that have a resolved outcome`

Where the denominator excludes unfilled opportunities, also report the **entry-trigger rate** separately:

`entry-trigger rate = actionable ideas with an eligible entry trigger / all matured actionable ideas`

Show both numerator and denominator. Report unfilled, gap-through, invalidated, censored/incomplete, and ambiguous counts separately; do not discard failed actionable plans without disclosure. Also show the combined **profitable opportunities per all matured actionable ideas** (positive net plans / all matured actionable ideas) to expose the effects of unfilled trades. The primary objective is the selected metric, not directional price prediction, and thresholds for inclusion must not be adjusted after seeing outcomes.

### Entry quality

- Entry-trigger rate and median/time-to-trigger.
- Fill rate conditional on trigger under the execution model.
- Median adverse/favorable difference between planned entry range and simulated fill.
- Expected and realized spread/slippage; gap-through count and unfilled/missed-entry count.
- Entry quality by data granularity/source, horizon and risk category.

### Stop-loss quality

- Stop-before-target count/rate among realistically filled positions.
- Planned per-share/position risk versus simulated net loss and stop slippage/gap loss.
- Loss containment: net realized loss as a fraction of planned risk (report median/tails).
- Stops followed by a predefined significant rebound within a predefined follow-up window, reported as a diagnostic only; do not retroactively alter the exit.

### Target quality

- Target-before-stop count/rate among realistically filled positions.
- Target attainment time, net return at target after modeled costs, and missed targets after earlier stop.
- Report horizon exits and unresolved cases separately.

### Overall profitability and risk

- Net return by trade and in aggregate; average/median win and loss; expectancy.
- `profit factor = sum(net positive P&L) / abs(sum(net negative P&L))`; report undefined when there are no losses rather than substituting a fabricated value.
- Maximum peak-to-trough drawdown from a chronological equity curve, with cash/allocation assumptions shown.
- Benchmark-relative performance using a declared benchmark and matched dates; account for cash and unfilled positions.
- Turnover/cost share, concentration, and return by strategy/horizon/risk category/market regime.

## Sample adequacy and reporting

Every report states count of generated, actionable, matured, filled, unfilled, excluded and unresolved recommendations; observation start/end; source/data coverage and interval; evaluation horizon; strategy/prompt version; fees/spread/slippage assumptions; and confidence interval for rates when sample size supports it. Include segment size and do not imply certainty for small samples. A nominal 85% rate from a small or selectively saved sample is not evidence the goal was achieved.

Keep prospective paper observations and historical simulations separate. Report out-of-sample and walk-forward results independently from development/validation. No future price, filing, news, delisting status, or corporate action may enter decision-time features. Report data survivorship, stale/missing data, halts, splits, delisted-security, and point-in-time-news limitations.

## Status classification

Persist separate workflow statuses such as saved, favorited, ignored, accepted-for-paper-evaluation, expired, unfilled, and completed. These are not performance labels. Evaluation label is derived from frozen plan and observations: actionable/matured, entered/filled, positive or non-positive net result, exit type, stop/target order, or censored/unresolved. **Unfilled is never a win/loss** but contributes to trigger-rate denominator.

## 85% claim policy

Do not claim the goal is reached until the predeclared profitable-plan success rate has adequate matured observations, transparent uncertainty, independent out-of-sample/walk-forward validation, complete failure/unfilled reporting, and stable results across relevant conditions. Show entry, stop, target, profitability and sample/coverage measures together. Never change old recommendations, filters, target rules, or denominators to improve historical results.
