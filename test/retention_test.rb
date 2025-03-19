# frozen_string_literal: true

require 'csv'
require 'date'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'

class RetentionTest < Minitest::Test
  def setup
    @project_dir = File.expand_path('..', __dir__)
    @sample_csv = File.join(@project_dir, 'data', 'sample_donations.csv')
    @as_of = '2026-02-01'
  end

  def test_retention_section_in_output
    stdout, stderr, status = Open3.capture3(
      'ruby', File.join(@project_dir, 'donor_briefs.rb'),
      '--input', @sample_csv,
      '--as-of', @as_of
    )

    assert status.success?, "Expected CLI success, stderr: #{stderr}"
    assert_includes stdout, 'Retention (last 12 months)'
    assert_match(/Retained donors: \d+ \(\d+\.\d%\)/, stdout)
  end

  def test_retention_json_matches_windows
    Dir.mktmpdir do |dir|
      json_path = File.join(dir, 'brief.json')
      stdout, stderr, status = Open3.capture3(
        'ruby', File.join(@project_dir, 'donor_briefs.rb'),
        '--input', @sample_csv,
        '--as-of', @as_of,
        '--json', json_path
      )

      assert status.success?, "Expected CLI success, stderr: #{stderr}\nstdout: #{stdout}"
      report = JSON.parse(File.read(json_path))
      retention = report.fetch('retention')

      recent_start = Date.parse(retention.fetch('recent_start'))
      recent_end = Date.parse(retention.fetch('recent_end'))
      prior_start = Date.parse(retention.fetch('prior_start'))
      prior_end = Date.parse(retention.fetch('prior_end'))

      assert_equal Date.parse(@as_of) - 365, recent_start
      assert_equal Date.parse(@as_of), recent_end
      assert_equal recent_start - 365, prior_start
      assert_equal recent_start - 1, prior_end

      expected = compute_expected_retention(prior_start, prior_end, recent_start, recent_end)
      assert_equal expected[:prior_donors], retention.fetch('prior_donors')
      assert_equal expected[:recent_donors], retention.fetch('recent_donors')
      assert_equal expected[:retained_donors], retention.fetch('retained_donors')
      assert_equal expected[:reactivated_donors], retention.fetch('reactivated_donors')
      assert_equal expected[:churned_donors], retention.fetch('churned_donors')
    end
  end

  private

  def compute_expected_retention(prior_start, prior_end, recent_start, recent_end)
    totals = Hash.new { |hash, key| hash[key] = { prior: 0.0, recent: 0.0 } }

    CSV.foreach(@sample_csv, headers: true) do |row|
      donor_key = row['donor_id']
      date = Date.parse(row['gift_date'])
      amount = row['gift_amount'].to_f

      if date >= recent_start && date <= recent_end
        totals[donor_key][:recent] += amount
      elsif date >= prior_start && date <= prior_end
        totals[donor_key][:prior] += amount
      end
    end

    prior_donors = totals.select { |_, v| v[:prior].positive? }
    recent_donors = totals.select { |_, v| v[:recent].positive? }
    retained = totals.select { |_, v| v[:prior].positive? && v[:recent].positive? }
    reactivated = totals.select { |_, v| v[:prior].zero? && v[:recent].positive? }
    churned = totals.select { |_, v| v[:prior].positive? && v[:recent].zero? }

    {
      prior_donors: prior_donors.length,
      recent_donors: recent_donors.length,
      retained_donors: retained.length,
      reactivated_donors: reactivated.length,
      churned_donors: churned.length
    }
  end
end
