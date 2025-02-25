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
