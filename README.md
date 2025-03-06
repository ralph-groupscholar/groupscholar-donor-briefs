# Group Scholar Donor Briefs

Group Scholar Donor Briefs is a Ruby CLI that turns a donation export into an executive-ready donor brief. It summarizes fundraising health, top donors, lapsed donors, campaign mix, and pledge coverage in one pass, plus an optional JSON report for downstream dashboards.

## Features

- Summarizes total raised, gift counts, unique donors, averages, median, and extremes.
- Ranks top donors by total contributions.
- Flags lapsed donors based on configurable inactivity windows.
- Breaks down campaign totals and gift counts.
- Tracks pledged vs received amounts and highlights overdue pledges.
- Flags unacknowledged gifts past a configurable acknowledgement grace window and reports acknowledgement performance.
- Adds acknowledgement performance metrics (acknowledged rate and average days to acknowledge).
- Adds momentum stats (recent vs prior window), new donors, and reactivated donors.
- Adds engagement stats (one-time vs repeat donors and average gifts per donor).
- Adds recency buckets to show donor mix by last gift.
- Adds a 12-month monthly trend for gifts and totals.
- Groups donors into major/mid/small tiers with configurable thresholds.
- Builds a stewardship queue prioritizing open pledges and lapsed value.
- Adds donor concentration metrics (top 5/10 share and largest donor share).
- Emits a structured JSON report for sharing or automation.
- Optionally syncs briefs to Postgres, including acknowledgement performance metrics, stewardship queue, recency buckets, and monthly trend.

## Requirements

- Ruby 2.6+

## Usage

```bash
ruby donor_briefs.rb --input data/sample_donations.csv
```

### Options

- `--input PATH` (required): CSV export of gifts
- `--lapsed-days N`: days since last gift to mark lapsed (default 365)
- `--top N`: number of top donors to list (default 5)
- `--json PATH`: write JSON report to a file
- `--as-of YYYY-MM-DD`: evaluate lapsed/overdue logic as of this date
- `--recent-days N`: recent window for momentum metrics (default 90)
- `--major-threshold N`: major donor threshold (default 10000)
- `--mid-threshold N`: mid-tier threshold (default 1000)
- `--queue N`: stewardship queue size (default 10)
- `--ack-days N`: days before unacknowledged gifts are flagged (default 7)
- `--db-sync`: store the brief in Postgres (uses env vars below)
- `--db-schema NAME`: Postgres schema for storage (default `donor_briefs`)

Example with JSON output:

```bash
ruby donor_briefs.rb --input data/sample_donations.csv --lapsed-days 540 --top 8 --recent-days 120 --major-threshold 15000 --json donor_brief.json
```

Example with Postgres sync:

```bash
DONOR_BRIEFS_DB_HOST=... DONOR_BRIEFS_DB_PORT=... DONOR_BRIEFS_DB_NAME=... \
DONOR_BRIEFS_DB_USER=... DONOR_BRIEFS_DB_PASSWORD=... \
ruby donor_briefs.rb --input data/sample_donations.csv --db-sync
```

### Database Environment Variables

- `DONOR_BRIEFS_DB_HOST`
- `DONOR_BRIEFS_DB_PORT`
- `DONOR_BRIEFS_DB_NAME`
- `DONOR_BRIEFS_DB_USER`
- `DONOR_BRIEFS_DB_PASSWORD`
- `DONOR_BRIEFS_DB_URL` (optional full connection string)

Database tables created:

- `brief_runs` (summary metrics + JSON payload)
- `top_donors`
- `stewardship_queue`
- `recency_buckets`
- `monthly_trend`

## CSV Headers

The CLI looks for these headers (case-insensitive). Alternate header names are supported.

- `donor_id`, `donor_name`, `email`
- `gift_date`, `gift_amount`
- `pledge_amount`, `pledge_due`
- `campaign`
- `acknowledged` or `thank_you_sent_date`

At minimum, the file must include `gift_date` and `gift_amount`.

## Notes

- Rows with invalid dates or amounts are skipped and surfaced under Warnings.
- Pledges are summed per donor; open pledges are calculated as pledged minus received.
- Campaign names default to `Unspecified` when blank.
- Database writes are intended for production usage; do not hardcode credentials.

## Project Files

- `donor_briefs.rb`: main CLI
- `data/sample_donations.csv`: sample dataset
- `ralph-progress.md`: iteration log

## Technology

- Ruby (standard library: CSV, JSON, OptionParser)
- Optional: `pg` gem for Postgres syncing
