# Group Scholar Donor Briefs

Group Scholar Donor Briefs is a Ruby CLI that turns a donation export into an executive-ready donor brief. It summarizes fundraising health, top donors, lapsed donors, campaign mix, and pledge coverage in one pass, plus an optional JSON report for downstream dashboards.

## Features

- Summarizes total raised, gift counts, unique donors, averages, median, and extremes.
- Ranks top donors by total contributions.
- Flags lapsed donors based on configurable inactivity windows.
- Breaks down campaign totals and gift counts.
- Tracks pledged vs received amounts and highlights overdue pledges.
- Emits a structured JSON report for sharing or automation.

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

Example with JSON output:

```bash
ruby donor_briefs.rb --input data/sample_donations.csv --lapsed-days 540 --top 8 --json donor_brief.json
```

## CSV Headers

The CLI looks for these headers (case-insensitive). Alternate header names are supported.

- `donor_id`, `donor_name`, `email`
- `gift_date`, `gift_amount`
- `pledge_amount`, `pledge_due`
- `campaign`

At minimum, the file must include `gift_date` and `gift_amount`.

## Notes

- Rows with invalid dates or amounts are skipped and surfaced under Warnings.
- Pledges are summed per donor; open pledges are calculated as pledged minus received.
- Campaign names default to `Unspecified` when blank.

## Project Files

- `donor_briefs.rb`: main CLI
- `data/sample_donations.csv`: sample dataset
- `ralph-progress.md`: iteration log

## Technology

- Ruby (standard library: CSV, JSON, OptionParser)
