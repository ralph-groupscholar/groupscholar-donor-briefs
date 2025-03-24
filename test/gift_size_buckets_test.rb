# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'

class GiftSizeBucketsTest < Minitest::Test
  def setup
    @project_dir = File.expand_path('..', __dir__)
    @sample_csv = File.join(@project_dir, 'data', 'sample_donations.csv')
    @as_of = '2026-02-01'
  end

  def test_gift_size_buckets_roll_up_totals
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

      summary = report.fetch('summary')
      buckets = report.fetch('gift_size_buckets')

      assert buckets.any?, 'Expected gift size buckets to be present'
      labels = buckets.map { |bucket| bucket.fetch('label') }
      assert_includes labels, 'Under $100'
      assert_includes labels, '$10,000+'

      total_gifts = buckets.sum { |bucket| bucket.fetch('gifts') }
      total_amount = buckets.sum { |bucket| bucket.fetch('total_amount') }

      assert_equal summary.fetch('total_gifts'), total_gifts
      assert_in_delta summary.fetch('total_raised'), total_amount, 0.01
    end
  end
end
