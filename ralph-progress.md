# Ralph Progress Log

## Iteration 34
- Added momentum analytics (recent vs prior window), new donor and reactivation counts, and average gift interval metrics.
- Introduced donor tiering with configurable major/mid thresholds.
- Built a stewardship queue that prioritizes open pledges and lapsed value, and extended JSON output accordingly.

## Iteration 36
- Started Group Scholar Donor Briefs, a Ruby CLI that turns donation exports into donor briefs with top donors, lapsed flags, campaign mix, and pledge coverage.
- Implemented `donor_briefs.rb` with CSV parsing, summary stats, lapsed and pledge logic, and JSON export.
- Added sample data and README usage notes.

## Iteration 50
- Added acknowledgement backlog tracking with a configurable grace window and donor-level rollups.
- Updated the JSON report, CLI output, and sample data to include acknowledgement signals.
- Documented the new acknowledgement options and headers in the README.

## Iteration 51
- Added donor concentration metrics (top 5/10 share and largest donor share) to the CLI output.
- Extended JSON report with concentration totals and shares for downstream dashboards.
- Documented the new concentration insight in the README.

## Iteration 52
- Added optional Postgres syncing for donor briefs with schema/table creation and top-donor inserts.
- Documented database environment variables and usage in the README.
- Seeded the production database with sample donor brief data.

## Iteration 87
- Added engagement metrics (one-time vs repeat donors, average gifts per donor) to CLI output and JSON.
- Added recency buckets based on last gift date to highlight donor mix and value concentration.
- Updated README feature list to cover the new engagement insights.

## Iteration 78
- Added acknowledgement performance metrics (acknowledged rate, latency, on-time acknowledgements) to CLI output and JSON.
- Extended sample data with thank-you sent dates to drive acknowledgement timing insights.
- Updated README to document the new acknowledgement performance coverage.

## Iteration 88
- Added a 12-month monthly trend rollup with gift totals and counts.
- Printed the monthly trend in CLI output and included it in the JSON report.
- Documented the monthly trend feature in the README.

## Iteration 89
- Added Postgres storage for monthly trend rows alongside each brief run.
- Updated database schema creation to include a monthly_trend table.
- Documented the new database table in the README.

## Iteration 96
- Extended Postgres sync to store stewardship queue and recency bucket detail tables.
- Added engagement metrics columns to brief_runs and backfilled with safe ALTERs.
- Updated README with database table list and reseeded production data.
