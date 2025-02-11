#!/usr/bin/env ruby
# frozen_string_literal: true

require 'csv'
require 'json'
require 'optparse'
require 'date'

ALIASES = {
  donor_id: %w[donor_id id donorid constituent_id constituentid],
  donor_name: %w[donor_name name donor full_name],
  email: %w[email email_address emailaddress],
  gift_date: %w[gift_date date donation_date received_date giftdate],
  gift_amount: %w[gift_amount amount donation_amount gift giftamount],
  pledge_amount: %w[pledge_amount pledge pledge_total pledged_amount],
  pledge_due: %w[pledge_due pledge_due_date due_date pledged_due],
  campaign: %w[campaign fund campaign_name appeal]
}.freeze

Options = Struct.new(:input, :lapsed_days, :top, :json_path, :as_of)

options = Options.new
options.lapsed_days = 365
options.top = 5
options.json_path = nil
options.as_of = Date.today

parser = OptionParser.new do |opts|
  opts.banner = "Usage: donor_briefs.rb --input PATH [options]"
  opts.on("-i", "--input PATH", "Path to donations CSV") { |v| options.input = v }
  opts.on("-l", "--lapsed-days N", Integer, "Days since last gift to mark lapsed (default 365)") { |v| options.lapsed_days = v }
  opts.on("-t", "--top N", Integer, "Top donors to display (default 5)") { |v| options.top = v }
  opts.on("-j", "--json PATH", "Write JSON report to PATH") { |v| options.json_path = v }
  opts.on("-a", "--as-of DATE", "Use this date for lapsed/overdue checks (YYYY-MM-DD)") { |v| options.as_of = Date.parse(v) }
  opts.on("-h", "--help", "Show help") do
    puts opts
    exit 0
  end
end

begin
  parser.parse!
rescue OptionParser::InvalidOption, OptionParser::MissingArgument => e
  warn e.message
  warn parser
  exit 1
end

if options.input.nil?
  warn "Missing --input"
  warn parser
  exit 1
end

unless File.exist?(options.input)
  warn "Input not found: #{options.input}"
  exit 1
end

def normalize_header(header)
  header.to_s.strip.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/_+/, '_')
end

def parse_amount(raw)
  return nil if raw.nil?
  cleaned = raw.to_s.strip
  return nil if cleaned.empty?
  cleaned = cleaned.gsub(/[^0-9.\-]/, '')
  return nil if cleaned.empty?
  Float(cleaned)
rescue ArgumentError
  nil
end

def parse_date(raw)
  return nil if raw.nil?
  cleaned = raw.to_s.strip
  return nil if cleaned.empty?
  Date.parse(cleaned)
rescue ArgumentError
  nil
end

def format_money(value)
  format("$%.2f", value)
end

rows = CSV.read(options.input, headers: true)

if rows.headers.nil?
  warn "CSV appears to have no headers"
  exit 1
end

normalized_headers = {}
rows.headers.each do |header|
  normalized_headers[normalize_header(header)] = header
end

header_map = {}
ALIASES.each do |key, aliases|
  aliases.each do |alias_key|
    actual = normalized_headers[alias_key]
    next if actual.nil?

    header_map[key] = actual
    break
  end
end

required = %i[gift_date gift_amount]
missing_required = required.reject { |key| header_map[key] }

if missing_required.any?
  warn "Missing required headers: #{missing_required.join(', ')}"
  warn "Found headers: #{rows.headers.join(', ')}"
  exit 1
end

warnings = []

stats = {
  total_raised: 0.0,
  gift_amounts: [],
  total_gifts: 0,
  campaigns: Hash.new { |hash, key| hash[key] = { total: 0.0, count: 0 } },
  donors: {}
}

rows.each_with_index do |row, index|
  gift_date = parse_date(row[header_map[:gift_date]])
  gift_amount = parse_amount(row[header_map[:gift_amount]])

  if gift_date.nil?
    warnings << "Row #{index + 2}: invalid gift_date"
    next
  end

  if gift_amount.nil? || gift_amount <= 0
    warnings << "Row #{index + 2}: invalid gift_amount"
    next
  end

  donor_id = header_map[:donor_id] ? row[header_map[:donor_id]]&.strip : nil
  donor_name = header_map[:donor_name] ? row[header_map[:donor_name]]&.strip : nil
  email = header_map[:email] ? row[header_map[:email]]&.strip : nil

  donor_key = donor_id
  donor_key = email if (donor_key.nil? || donor_key.empty?) && email && !email.empty?
  donor_key = donor_name if (donor_key.nil? || donor_key.empty?) && donor_name && !donor_name.empty?
  if donor_key.nil? || donor_key.empty?
    donor_key = "unknown-#{index + 1}"
    warnings << "Row #{index + 2}: missing donor identity"
  end

  donor = stats[:donors][donor_key] ||= {
    id: donor_id,
    name: donor_name,
    email: email,
    total_amount: 0.0,
    total_gifts: 0,
    first_gift_date: gift_date,
    last_gift_date: gift_date,
    pledge_total: 0.0,
    pledge_due_dates: []
  }

  donor[:name] = donor_name if donor[:name].nil? || donor[:name].empty?
  donor[:email] = email if donor[:email].nil? || donor[:email].empty?

  donor[:total_amount] += gift_amount
  donor[:total_gifts] += 1
  donor[:first_gift_date] = gift_date if gift_date < donor[:first_gift_date]
  donor[:last_gift_date] = gift_date if gift_date > donor[:last_gift_date]

  pledge_amount = header_map[:pledge_amount] ? parse_amount(row[header_map[:pledge_amount]]) : nil
  pledge_due = header_map[:pledge_due] ? parse_date(row[header_map[:pledge_due]]) : nil
  if pledge_amount && pledge_amount.positive?
    donor[:pledge_total] += pledge_amount
    donor[:pledge_due_dates] << pledge_due if pledge_due
  end

  campaign = header_map[:campaign] ? row[header_map[:campaign]]&.strip : nil
  campaign = "Unspecified" if campaign.nil? || campaign.empty?

  stats[:total_raised] += gift_amount
  stats[:gift_amounts] << gift_amount
  stats[:total_gifts] += 1
  stats[:campaigns][campaign][:total] += gift_amount
  stats[:campaigns][campaign][:count] += 1
end

if stats[:total_gifts].zero?
  warn "No valid gift rows found after validation"
  exit 1
end

as_of = options.as_of
lapsed_cutoff = as_of - options.lapsed_days

sorted_amounts = stats[:gift_amounts].sort
median = if sorted_amounts.length.odd?
  sorted_amounts[sorted_amounts.length / 2]
else
  mid = sorted_amounts.length / 2
  (sorted_amounts[mid - 1] + sorted_amounts[mid]) / 2.0
end

unique_donors = stats[:donors].length
average_gift = stats[:total_raised] / stats[:total_gifts]

sorted_donors = stats[:donors].values.sort_by { |donor| -donor[:total_amount] }

lapsed_donors = stats[:donors].values.select { |donor| donor[:last_gift_date] < lapsed_cutoff }

campaigns_sorted = stats[:campaigns].map do |name, data|
  { name: name, total: data[:total], count: data[:count] }
end.sort_by { |item| -item[:total] }

pledge_total = stats[:donors].values.sum { |donor| donor[:pledge_total] }
open_pledges = stats[:donors].values.map do |donor|
  open_amount = donor[:pledge_total] - donor[:total_amount]
  open_amount = 0.0 if open_amount.negative?
  donor.merge(open_amount: open_amount)
end

open_total = open_pledges.sum { |donor| donor[:open_amount] }

overdue = open_pledges.select do |donor|
  next false if donor[:open_amount].zero?
  next false if donor[:pledge_due_dates].empty?

  donor[:pledge_due_dates].min < as_of
end

puts "Group Scholar Donor Brief"
puts "As of: #{as_of}"
puts "Input: #{options.input}"
puts
puts "Summary"
puts "- Total raised: #{format_money(stats[:total_raised])}"
puts "- Total gifts: #{stats[:total_gifts]}"
puts "- Unique donors: #{unique_donors}"
puts "- Average gift: #{format_money(average_gift)}"
puts "- Median gift: #{format_money(median)}"
puts "- Largest gift: #{format_money(sorted_amounts.last)}"
puts "- First gift: #{stats[:donors].values.map { |d| d[:first_gift_date] }.min}"
puts "- Latest gift: #{stats[:donors].values.map { |d| d[:last_gift_date] }.max}"
puts
puts "Top Donors"
sorted_donors.first(options.top).each_with_index do |donor, idx|
  label = donor[:name].to_s.strip
  label = donor[:email].to_s.strip if label.empty?
  label = donor[:id].to_s.strip if label.empty?
  label = "Unknown Donor" if label.empty?
  puts "#{idx + 1}. #{label} - #{format_money(donor[:total_amount])} (#{donor[:total_gifts]} gifts)"
end
puts
puts "Campaign Breakdown"
campaigns_sorted.first(5).each do |campaign|
  puts "- #{campaign[:name]}: #{format_money(campaign[:total])} (#{campaign[:count]} gifts)"
end
puts
puts "Lapsed Donors (no gift since #{lapsed_cutoff})"
puts "- Total lapsed: #{lapsed_donors.length}"
lapsed_donors.sort_by { |donor| donor[:last_gift_date] }.first(10).each do |donor|
  label = donor[:name].to_s.strip
  label = donor[:email].to_s.strip if label.empty?
  label = donor[:id].to_s.strip if label.empty?
  label = "Unknown Donor" if label.empty?
  puts "  - #{label}: last gift #{donor[:last_gift_date]}, total #{format_money(donor[:total_amount])}"
end
puts
puts "Pledge Coverage"
puts "- Total pledged: #{format_money(pledge_total)}"
puts "- Total received: #{format_money(stats[:total_raised])}"
puts "- Open pledges: #{format_money(open_total)}"
puts "- Overdue pledges: #{overdue.length}"
overdue.first(10).each do |donor|
  label = donor[:name].to_s.strip
  label = donor[:email].to_s.strip if label.empty?
  label = donor[:id].to_s.strip if label.empty?
  label = "Unknown Donor" if label.empty?
  next_due = donor[:pledge_due_dates].min
  puts "  - #{label}: #{format_money(donor[:open_amount])} overdue since #{next_due}"
end

if warnings.any?
  puts
  puts "Warnings"
  warnings.first(10).each { |warning| puts "- #{warning}" }
  remaining = warnings.length - 10
  puts "- #{remaining} more warnings" if remaining.positive?
end

report = {
  as_of: as_of.to_s,
  input: options.input,
  summary: {
    total_raised: stats[:total_raised],
    total_gifts: stats[:total_gifts],
    unique_donors: unique_donors,
    average_gift: average_gift,
    median_gift: median,
    largest_gift: sorted_amounts.last,
    first_gift: stats[:donors].values.map { |d| d[:first_gift_date] }.min.to_s,
    latest_gift: stats[:donors].values.map { |d| d[:last_gift_date] }.max.to_s
  },
  top_donors: sorted_donors.first(options.top).map do |donor|
    {
      id: donor[:id],
      name: donor[:name],
      email: donor[:email],
      total_amount: donor[:total_amount],
      total_gifts: donor[:total_gifts],
      first_gift_date: donor[:first_gift_date].to_s,
      last_gift_date: donor[:last_gift_date].to_s
    }
  end,
  campaigns: campaigns_sorted,
  lapsed: {
    cutoff: lapsed_cutoff.to_s,
    total: lapsed_donors.length,
    donors: lapsed_donors.sort_by { |donor| donor[:last_gift_date] }.map do |donor|
      {
        id: donor[:id],
        name: donor[:name],
        email: donor[:email],
        total_amount: donor[:total_amount],
        total_gifts: donor[:total_gifts],
        last_gift_date: donor[:last_gift_date].to_s
      }
    end
  },
  pledges: {
    total_pledged: pledge_total,
    total_received: stats[:total_raised],
    open_total: open_total,
    overdue_total: overdue.length,
    overdue: overdue.map do |donor|
      {
        id: donor[:id],
        name: donor[:name],
        email: donor[:email],
        open_amount: donor[:open_amount],
        next_due: donor[:pledge_due_dates].min.to_s
      }
    end
  },
  warnings: warnings
}

if options.json_path
  File.write(options.json_path, JSON.pretty_generate(report))
end
