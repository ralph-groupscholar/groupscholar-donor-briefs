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
  campaign: %w[campaign fund campaign_name appeal],
  ack_status: %w[acknowledged ack_status thank_you_sent thank_you_sent_flag thanked],
  ack_date: %w[thank_you_sent_date thank_you_date acknowledgement_date acknowledged_date]
}.freeze

Options = Struct.new(:input, :lapsed_days, :top, :json_path, :as_of, :recent_days, :major_threshold, :mid_threshold, :queue, :ack_days, :db_sync, :db_schema)

options = Options.new
options.lapsed_days = 365
options.top = 5
options.json_path = nil
options.as_of = Date.today
options.recent_days = 90
options.major_threshold = 10_000
options.mid_threshold = 1_000
options.queue = 10
options.ack_days = 7
options.db_sync = false
options.db_schema = 'donor_briefs'

parser = OptionParser.new do |opts|
  opts.banner = "Usage: donor_briefs.rb --input PATH [options]"
  opts.on("-i", "--input PATH", "Path to donations CSV") { |v| options.input = v }
  opts.on("-l", "--lapsed-days N", Integer, "Days since last gift to mark lapsed (default 365)") { |v| options.lapsed_days = v }
  opts.on("-t", "--top N", Integer, "Top donors to display (default 5)") { |v| options.top = v }
  opts.on("-j", "--json PATH", "Write JSON report to PATH") { |v| options.json_path = v }
  opts.on("-a", "--as-of DATE", "Use this date for lapsed/overdue checks (YYYY-MM-DD)") { |v| options.as_of = Date.parse(v) }
  opts.on("--recent-days N", Integer, "Recent window in days for momentum metrics (default 90)") { |v| options.recent_days = v }
  opts.on("--major-threshold N", Integer, "Major donor threshold (default 10000)") { |v| options.major_threshold = v }
  opts.on("--mid-threshold N", Integer, "Mid-tier donor threshold (default 1000)") { |v| options.mid_threshold = v }
  opts.on("--queue N", Integer, "Stewardship queue size (default 10)") { |v| options.queue = v }
  opts.on("--ack-days N", Integer, "Days before unacknowledged gifts are flagged (default 7)") { |v| options.ack_days = v }
  opts.on("--db-sync", "Write report to Postgres (uses DONOR_BRIEFS_DB_* env vars)") { options.db_sync = true }
  opts.on("--db-schema NAME", "Postgres schema for storage (default donor_briefs)") { |v| options.db_schema = v }
  opts.on("-h", "--help", "Show help") do
    puts opts
    exit 0
  end
end

def load_pg!
  require 'pg'
rescue LoadError
  warn "Missing pg gem. Install with `gem install pg` to use --db-sync."
  exit 1
end

def db_connection_params
  url = ENV['DONOR_BRIEFS_DB_URL']
  return url if url && !url.strip.empty?

  host = ENV['DONOR_BRIEFS_DB_HOST'] || ENV['DB_HOST']
  port = ENV['DONOR_BRIEFS_DB_PORT'] || ENV['DB_PORT']
  dbname = ENV['DONOR_BRIEFS_DB_NAME'] || ENV['DB_NAME'] || 'postgres'
  user = ENV['DONOR_BRIEFS_DB_USER'] || ENV['DB_USER']
  password = ENV['DONOR_BRIEFS_DB_PASSWORD'] || ENV['DB_PASSWORD']

  missing = []
  missing << 'DONOR_BRIEFS_DB_HOST' if host.nil? || host.strip.empty?
  missing << 'DONOR_BRIEFS_DB_USER' if user.nil? || user.strip.empty?
  missing << 'DONOR_BRIEFS_DB_PASSWORD' if password.nil? || password.strip.empty?

  unless missing.empty?
    warn "Missing DB env vars: #{missing.join(', ')}"
    exit 1
  end

  {
    host: host,
    port: port,
    dbname: dbname,
    user: user,
    password: password
  }
end

def ensure_db_schema(conn, schema)
  schema_ident = PG::Connection.quote_ident(schema)

  conn.exec("CREATE SCHEMA IF NOT EXISTS #{schema_ident}")
  conn.exec(<<~SQL)
    CREATE TABLE IF NOT EXISTS #{schema_ident}.brief_runs (
      id bigserial primary key,
      run_at timestamptz not null,
      as_of date not null,
      input_path text not null,
      total_raised numeric not null,
      total_gifts integer not null,
      unique_donors integer not null,
      average_gift numeric not null,
      median_gift numeric not null,
      largest_gift numeric not null,
      top5_share numeric not null,
      top10_share numeric not null,
      largest_donor_share numeric not null,
      recent_total numeric not null,
      prior_total numeric not null,
      delta_total numeric not null,
      delta_gifts integer not null,
      acknowledged_gifts integer not null default 0,
      acknowledged_total numeric not null default 0,
      acknowledged_rate numeric not null default 0,
      ack_latency_avg numeric,
      ack_latency_median numeric,
      on_time_gifts integer not null default 0,
      on_time_rate numeric not null default 0,
      unacknowledged_total numeric not null,
      unacknowledged_gifts integer not null,
      open_pledges numeric not null,
      overdue_pledges integer not null,
      one_time_donors integer not null default 0,
      repeat_donors integer not null default 0,
      avg_gifts_per_donor numeric not null default 0,
      report jsonb not null
    );
  SQL
  conn.exec("ALTER TABLE #{schema_ident}.brief_runs ADD COLUMN IF NOT EXISTS one_time_donors integer not null default 0;")
  conn.exec("ALTER TABLE #{schema_ident}.brief_runs ADD COLUMN IF NOT EXISTS repeat_donors integer not null default 0;")
  conn.exec("ALTER TABLE #{schema_ident}.brief_runs ADD COLUMN IF NOT EXISTS avg_gifts_per_donor numeric not null default 0;")
  conn.exec("ALTER TABLE #{schema_ident}.brief_runs ADD COLUMN IF NOT EXISTS acknowledged_gifts integer not null default 0;")
  conn.exec("ALTER TABLE #{schema_ident}.brief_runs ADD COLUMN IF NOT EXISTS acknowledged_total numeric not null default 0;")
  conn.exec("ALTER TABLE #{schema_ident}.brief_runs ADD COLUMN IF NOT EXISTS acknowledged_rate numeric not null default 0;")
  conn.exec("ALTER TABLE #{schema_ident}.brief_runs ADD COLUMN IF NOT EXISTS ack_latency_avg numeric;")
  conn.exec("ALTER TABLE #{schema_ident}.brief_runs ADD COLUMN IF NOT EXISTS ack_latency_median numeric;")
  conn.exec("ALTER TABLE #{schema_ident}.brief_runs ADD COLUMN IF NOT EXISTS on_time_gifts integer not null default 0;")
  conn.exec("ALTER TABLE #{schema_ident}.brief_runs ADD COLUMN IF NOT EXISTS on_time_rate numeric not null default 0;")
  conn.exec(<<~SQL)
    CREATE TABLE IF NOT EXISTS #{schema_ident}.top_donors (
      id bigserial primary key,
      run_id bigint references #{schema_ident}.brief_runs(id) on delete cascade,
      donor_id text,
      donor_name text,
      donor_email text,
      total_amount numeric not null,
      total_gifts integer not null,
      last_gift_date date
    );
  SQL
  conn.exec(<<~SQL)
    CREATE TABLE IF NOT EXISTS #{schema_ident}.stewardship_queue (
      id bigserial primary key,
      run_id bigint references #{schema_ident}.brief_runs(id) on delete cascade,
      donor_id text,
      donor_name text,
      donor_email text,
      total_amount numeric not null,
      open_amount numeric not null,
      last_gift_date date,
      priority_score numeric not null,
      lapsed boolean not null
    );
  SQL
  conn.exec(<<~SQL)
    CREATE TABLE IF NOT EXISTS #{schema_ident}.recency_buckets (
      id bigserial primary key,
      run_id bigint references #{schema_ident}.brief_runs(id) on delete cascade,
      label text not null,
      min_days integer not null,
      max_days integer,
      donors integer not null,
      total_amount numeric not null,
      donor_share numeric not null,
      total_share numeric not null
    );
  SQL
  conn.exec(<<~SQL)
    CREATE TABLE IF NOT EXISTS #{schema_ident}.monthly_trend (
      id bigserial primary key,
      run_id bigint references #{schema_ident}.brief_runs(id) on delete cascade,
      month date not null,
      total_amount numeric not null,
      gifts integer not null
    );
  SQL
end

def persist_report(report, options, stats, top_donors, concentration, momentum, acknowledgements, pledges, monthly_trend)
  load_pg!
  conn = PG.connect(db_connection_params)
  ensure_db_schema(conn, options.db_schema)

  schema_ident = PG::Connection.quote_ident(options.db_schema)
  run_at = Time.now.utc

  result = conn.exec_params(
    <<~SQL,
      INSERT INTO #{schema_ident}.brief_runs (
        run_at, as_of, input_path,
        total_raised, total_gifts, unique_donors, average_gift, median_gift, largest_gift,
        top5_share, top10_share, largest_donor_share,
        recent_total, prior_total, delta_total, delta_gifts,
        acknowledged_gifts, acknowledged_total, acknowledged_rate,
        ack_latency_avg, ack_latency_median,
        on_time_gifts, on_time_rate,
        unacknowledged_total, unacknowledged_gifts,
        open_pledges, overdue_pledges,
        one_time_donors, repeat_donors, avg_gifts_per_donor,
        report
      ) VALUES (
        $1, $2, $3,
        $4, $5, $6, $7, $8, $9,
        $10, $11, $12,
        $13, $14, $15, $16,
        $17, $18, $19,
        $20, $21,
        $22, $23,
        $24, $25,
        $26, $27,
        $28, $29, $30,
        $31
      ) RETURNING id;
    SQL
    [
      run_at,
      report[:as_of],
      options.input,
      stats[:total_raised],
      stats[:total_gifts],
      report[:summary][:unique_donors],
      report[:summary][:average_gift],
      report[:summary][:median_gift],
      report[:summary][:largest_gift],
      concentration[:top5_share],
      concentration[:top10_share],
      concentration[:largest_donor_share],
      momentum[:recent_total],
      momentum[:prior_total],
      momentum[:delta_total],
      momentum[:delta_gifts],
      acknowledgements[:acknowledged_gifts],
      acknowledgements[:acknowledged_total],
      acknowledgements[:acknowledged_rate],
      acknowledgements[:average_days_to_acknowledge],
      acknowledgements[:median_days_to_acknowledge],
      acknowledgements[:on_time_gifts],
      acknowledgements[:on_time_rate],
      acknowledgements[:unacknowledged_total],
      acknowledgements[:unacknowledged_gifts],
      pledges[:open_total],
      pledges[:overdue_total],
      report[:engagement][:one_time_donors],
      report[:engagement][:repeat_donors],
      report[:engagement][:average_gifts_per_donor],
      JSON.dump(report)
    ]
  )

  run_id = result[0]['id']

  top_donors.each do |donor|
    conn.exec_params(
      <<~SQL,
        INSERT INTO #{schema_ident}.top_donors (
          run_id, donor_id, donor_name, donor_email,
          total_amount, total_gifts, last_gift_date
        ) VALUES ($1, $2, $3, $4, $5, $6, $7);
      SQL
      [
        run_id,
        donor[:id],
        donor[:name],
        donor[:email],
        donor[:total_amount],
        donor[:total_gifts],
        donor[:last_gift_date]
      ]
    )
  end

  report[:stewardship_queue].each do |donor|
    conn.exec_params(
      <<~SQL,
        INSERT INTO #{schema_ident}.stewardship_queue (
          run_id, donor_id, donor_name, donor_email,
          total_amount, open_amount, last_gift_date, priority_score, lapsed
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9);
      SQL
      [
        run_id,
        donor[:id],
        donor[:name],
        donor[:email],
        donor[:total_amount],
        donor[:open_amount],
        donor[:last_gift_date],
        donor[:priority_score],
        donor[:lapsed]
      ]
    )
  end

  report[:recency_buckets].each do |bucket|
    conn.exec_params(
      <<~SQL,
        INSERT INTO #{schema_ident}.recency_buckets (
          run_id, label, min_days, max_days, donors, total_amount, donor_share, total_share
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8);
      SQL
      [
        run_id,
        bucket[:label],
        bucket[:min_days],
        bucket[:max_days],
        bucket[:donors],
        bucket[:total_amount],
        bucket[:donor_share],
        bucket[:total_share]
      ]
    )
  end

  monthly_trend.each do |entry|
    conn.exec_params(
      <<~SQL,
        INSERT INTO #{schema_ident}.monthly_trend (
          run_id, month, total_amount, gifts
        ) VALUES ($1, $2, $3, $4);
      SQL
      [
        run_id,
        Date.parse("#{entry[:month]}-01"),
        entry[:total],
        entry[:gifts]
      ]
    )
  end
ensure
  conn&.close
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

def format_percent(value)
  format("%.1f%%", value * 100.0)
end

def parse_acknowledged(status_raw, date_raw)
  return true if parse_date(date_raw)
  return false if status_raw.nil?

  value = status_raw.to_s.strip.downcase
  return true if %w[yes y true 1 sent acknowledged].include?(value)
  return false if %w[no n false 0 pending].include?(value)

  false
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
  donors: {},
  gifts: []
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
    pledge_due_dates: [],
    gift_dates: []
  }

  donor[:name] = donor_name if donor[:name].nil? || donor[:name].empty?
  donor[:email] = email if donor[:email].nil? || donor[:email].empty?

  donor[:total_amount] += gift_amount
  donor[:total_gifts] += 1
  donor[:first_gift_date] = gift_date if gift_date < donor[:first_gift_date]
  donor[:last_gift_date] = gift_date if gift_date > donor[:last_gift_date]
  donor[:gift_dates] << gift_date

  pledge_amount = header_map[:pledge_amount] ? parse_amount(row[header_map[:pledge_amount]]) : nil
  pledge_due = header_map[:pledge_due] ? parse_date(row[header_map[:pledge_due]]) : nil
  if pledge_amount && pledge_amount.positive?
    donor[:pledge_total] += pledge_amount
    donor[:pledge_due_dates] << pledge_due if pledge_due
  end

  campaign = header_map[:campaign] ? row[header_map[:campaign]]&.strip : nil
  campaign = "Unspecified" if campaign.nil? || campaign.empty?

  ack_status = header_map[:ack_status] ? row[header_map[:ack_status]] : nil
  ack_date_raw = header_map[:ack_date] ? row[header_map[:ack_date]] : nil
  ack_date = parse_date(ack_date_raw)
  acknowledged = parse_acknowledged(ack_status, ack_date_raw)

  stats[:gifts] << {
    donor_key: donor_key,
    donor_id: donor_id,
    donor_name: donor_name,
    donor_email: email,
    gift_date: gift_date,
    gift_amount: gift_amount,
    acknowledged: acknowledged,
    ack_date: ack_date
  }

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
recent_cutoff = as_of - options.recent_days
prior_cutoff = recent_cutoff - options.recent_days
ack_cutoff = as_of - options.ack_days

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

recent_total = 0.0
prior_total = 0.0
recent_gifts = 0
prior_gifts = 0

rows.each do |row|
  gift_date = parse_date(row[header_map[:gift_date]])
  gift_amount = parse_amount(row[header_map[:gift_amount]])
  next if gift_date.nil? || gift_amount.nil? || gift_amount <= 0

  if gift_date >= recent_cutoff
    recent_total += gift_amount
    recent_gifts += 1
  elsif gift_date >= prior_cutoff
    prior_total += gift_amount
    prior_gifts += 1
  end
end

campaigns_sorted = stats[:campaigns].map do |name, data|
  { name: name, total: data[:total], count: data[:count] }
end.sort_by { |item| -item[:total] }

top5_total = sorted_donors.first(5).sum { |donor| donor[:total_amount] }
top10_total = sorted_donors.first(10).sum { |donor| donor[:total_amount] }
largest_donor_total = sorted_donors.first ? sorted_donors.first[:total_amount] : 0.0
total_raised = stats[:total_raised]
top5_share = total_raised.positive? ? top5_total / total_raised : 0.0
top10_share = total_raised.positive? ? top10_total / total_raised : 0.0
largest_donor_share = total_raised.positive? ? largest_donor_total / total_raised : 0.0

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

donor_tiers = {
  major: { threshold: options.major_threshold, count: 0, total: 0.0 },
  mid: { threshold: options.mid_threshold, count: 0, total: 0.0 },
  small: { threshold: options.mid_threshold, count: 0, total: 0.0 }
}

new_donors = []
reactivated_donors = []
interval_days = []

stats[:donors].values.each do |donor|
  total = donor[:total_amount]
  if total >= options.major_threshold
    donor_tiers[:major][:count] += 1
    donor_tiers[:major][:total] += total
  elsif total >= options.mid_threshold
    donor_tiers[:mid][:count] += 1
    donor_tiers[:mid][:total] += total
  else
    donor_tiers[:small][:count] += 1
    donor_tiers[:small][:total] += total
  end

  new_donors << donor if donor[:first_gift_date] >= recent_cutoff

  dates = donor[:gift_dates].sort
  if dates.length >= 2
    dates.each_cons(2) { |a, b| interval_days << (b - a).to_i }
    last_gap = (dates[-1] - dates[-2]).to_i
    if donor[:last_gift_date] >= recent_cutoff && last_gap > options.lapsed_days
      reactivated_donors << donor
    end
  end
end

avg_interval = interval_days.empty? ? nil : (interval_days.sum.to_f / interval_days.length)

stewardship_queue = open_pledges.map do |donor|
  priority = (donor[:open_amount] * 2.0) + donor[:total_amount]
  if donor[:last_gift_date] < lapsed_cutoff
    priority += donor[:total_amount]
  end
  donor.merge(priority_score: priority)
end.sort_by { |donor| -donor[:priority_score] }

unacknowledged_gifts = stats[:gifts].select do |gift|
  !gift[:acknowledged] && gift[:gift_date] <= ack_cutoff
end

unacknowledged_total = unacknowledged_gifts.sum { |gift| gift[:gift_amount] }
unack_donors = Hash.new do |hash, key|
  hash[key] = { id: nil, name: nil, email: nil, total: 0.0, count: 0, last_gift_date: nil }
end

unacknowledged_gifts.each do |gift|
  entry = unack_donors[gift[:donor_key]]
  entry[:id] ||= gift[:donor_id]
  entry[:name] ||= gift[:donor_name]
  entry[:email] ||= gift[:donor_email]
  entry[:total] += gift[:gift_amount]
  entry[:count] += 1
  entry[:last_gift_date] = gift[:gift_date] if entry[:last_gift_date].nil? || gift[:gift_date] > entry[:last_gift_date]
end

unack_donors_sorted = unack_donors.values.sort_by { |entry| -entry[:total] }

acknowledged_gifts = stats[:gifts].select { |gift| gift[:acknowledged] }
acknowledged_total = acknowledged_gifts.sum { |gift| gift[:gift_amount] }
acknowledged_rate = stats[:total_gifts].positive? ? acknowledged_gifts.length.to_f / stats[:total_gifts] : 0.0

ack_latency_days = acknowledged_gifts.map do |gift|
  next nil unless gift[:ack_date]
  days = (gift[:ack_date] - gift[:gift_date]).to_i
  next nil if days.negative?
  days
end.compact

ack_latency_days_sorted = ack_latency_days.sort
ack_latency_avg = ack_latency_days.empty? ? nil : (ack_latency_days.sum.to_f / ack_latency_days.length)
ack_latency_median = if ack_latency_days_sorted.empty?
  nil
elsif ack_latency_days_sorted.length.odd?
  ack_latency_days_sorted[ack_latency_days_sorted.length / 2]
else
  mid = ack_latency_days_sorted.length / 2
  (ack_latency_days_sorted[mid - 1] + ack_latency_days_sorted[mid]) / 2.0
end

on_time_ack = stats[:gifts].select do |gift|
  next false unless gift[:ack_date]
  (gift[:ack_date] - gift[:gift_date]).to_i <= options.ack_days
end

on_time_rate = stats[:total_gifts].positive? ? on_time_ack.length.to_f / stats[:total_gifts] : 0.0

one_time_donors = stats[:donors].values.select { |donor| donor[:total_gifts] == 1 }
repeat_donors = stats[:donors].values.select { |donor| donor[:total_gifts] > 1 }
avg_gifts_per_donor = stats[:total_gifts].to_f / unique_donors

recent_year_start = as_of - 365
prior_year_start = recent_year_start - 365
prior_year_end = recent_year_start - 1

retention_totals = Hash.new { |hash, key| hash[key] = { recent: 0.0, prior: 0.0 } }
stats[:gifts].each do |gift|
  gift_date = gift[:gift_date]
  if gift_date >= recent_year_start && gift_date <= as_of
    retention_totals[gift[:donor_key]][:recent] += gift[:gift_amount]
  elsif gift_date >= prior_year_start && gift_date <= prior_year_end
    retention_totals[gift[:donor_key]][:prior] += gift[:gift_amount]
  end
end

prior_donors = retention_totals.select { |_, totals| totals[:prior].positive? }
recent_donors = retention_totals.select { |_, totals| totals[:recent].positive? }
retained_donors = retention_totals.select { |_, totals| totals[:prior].positive? && totals[:recent].positive? }
reactivated_12m = retention_totals.select { |_, totals| totals[:prior].zero? && totals[:recent].positive? }
churned_12m = retention_totals.select { |_, totals| totals[:prior].positive? && totals[:recent].zero? }
retention_rate = prior_donors.empty? ? 0.0 : retained_donors.length.to_f / prior_donors.length
retained_prior_total = retained_donors.values.sum { |totals| totals[:prior] }
retained_recent_total = retained_donors.values.sum { |totals| totals[:recent] }

recency_buckets = [
  { label: '0-30 days', min: 0, max: 30 },
  { label: '31-90 days', min: 31, max: 90 },
  { label: '91-180 days', min: 91, max: 180 },
  { label: '181-365 days', min: 181, max: 365 },
  { label: '366+ days', min: 366, max: nil }
].map { |bucket| bucket.merge(count: 0, total: 0.0) }

stats[:donors].values.each do |donor|
  days_since = (as_of - donor[:last_gift_date]).to_i
  bucket = recency_buckets.find do |entry|
    if entry[:max]
      days_since.between?(entry[:min], entry[:max])
    else
      days_since >= entry[:min]
    end
  end
  next unless bucket

  bucket[:count] += 1
  bucket[:total] += donor[:total_amount]
end

monthly_totals = Hash.new { |hash, key| hash[key] = { total: 0.0, gifts: 0 } }
stats[:gifts].each do |gift|
  month_key = Date.new(gift[:gift_date].year, gift[:gift_date].month, 1)
  monthly_totals[month_key][:total] += gift[:gift_amount]
  monthly_totals[month_key][:gifts] += 1
end

as_of_month = Date.new(as_of.year, as_of.month, 1)
last_12_months = (0..11).map { |offset| as_of_month << offset }.reverse
monthly_trend = last_12_months.map do |month|
  data = monthly_totals[month]
  {
    month: month.strftime('%Y-%m'),
    total: data[:total],
    gifts: data[:gifts]
  }
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
puts "Concentration"
puts "- Top 5 donors share: #{format_percent(top5_share)} (#{format_money(top5_total)})"
puts "- Top 10 donors share: #{format_percent(top10_share)} (#{format_money(top10_total)})"
puts "- Largest donor share: #{format_percent(largest_donor_share)} (#{format_money(largest_donor_total)})"
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

puts
puts "Acknowledgement Backlog (older than #{ack_cutoff})"
puts "- Unacknowledged gifts: #{unacknowledged_gifts.length}"
puts "- Unacknowledged total: #{format_money(unacknowledged_total)}"
unack_donors_sorted.first(10).each do |donor|
  label = donor[:name].to_s.strip
  label = donor[:email].to_s.strip if label.empty?
  label = donor[:id].to_s.strip if label.empty?
  label = "Unknown Donor" if label.empty?
  puts "  - #{label}: #{format_money(donor[:total])} across #{donor[:count]} gifts, last gift #{donor[:last_gift_date]}"
end

puts
puts "Acknowledgement Performance"
puts "- Acknowledged gifts: #{acknowledged_gifts.length} (#{format_percent(acknowledged_rate)})"
puts "- Acknowledged total: #{format_money(acknowledged_total)}"
latency_label = ack_latency_avg ? "#{ack_latency_avg.round(1)} days" : "n/a"
latency_median_label = ack_latency_median ? "#{ack_latency_median.round(1)} days" : "n/a"
puts "- Avg days to acknowledge: #{latency_label} (median #{latency_median_label})"
puts "- On-time acknowledgements (<= #{options.ack_days} days): #{on_time_ack.length} (#{format_percent(on_time_rate)})"

puts
puts "Momentum (last #{options.recent_days} days)"
puts "- Recent raised: #{format_money(recent_total)} (#{recent_gifts} gifts)"
puts "- Prior window: #{format_money(prior_total)} (#{prior_gifts} gifts)"
delta_total = recent_total - prior_total
delta_gifts = recent_gifts - prior_gifts
puts "- Delta raised: #{format_money(delta_total)}"
puts "- Delta gifts: #{delta_gifts}"
puts "- New donors: #{new_donors.length}"
puts "- Reactivated donors: #{reactivated_donors.length}"
puts "- Avg days between gifts: #{avg_interval ? avg_interval.round(1) : 'n/a'}"

puts
puts "Engagement"
puts "- One-time donors: #{one_time_donors.length} (#{format_percent(one_time_donors.length.to_f / unique_donors)})"
puts "- Repeat donors: #{repeat_donors.length} (#{format_percent(repeat_donors.length.to_f / unique_donors)})"
puts "- Avg gifts per donor: #{avg_gifts_per_donor.round(2)}"

puts
puts "Retention (last 12 months)"
puts "- Prior 12m donors: #{prior_donors.length}"
puts "- Recent 12m donors: #{recent_donors.length}"
puts "- Retained donors: #{retained_donors.length} (#{format_percent(retention_rate)})"
puts "- Reactivated donors: #{reactivated_12m.length}"
puts "- Churned donors: #{churned_12m.length}"
puts "- Retained donor value: #{format_money(retained_prior_total)} -> #{format_money(retained_recent_total)}"

puts
puts "Recency Buckets (by last gift)"
recency_buckets.each do |bucket|
  donor_share = unique_donors.positive? ? bucket[:count].to_f / unique_donors : 0.0
  total_share = total_raised.positive? ? bucket[:total] / total_raised : 0.0
  puts "- #{bucket[:label]}: #{bucket[:count]} donors, #{format_money(bucket[:total])} (#{format_percent(donor_share)} donors, #{format_percent(total_share)} total)"
end

puts
puts "Monthly Trend (last 12 months)"
monthly_trend.each do |entry|
  puts "- #{entry[:month]}: #{format_money(entry[:total])} (#{entry[:gifts]} gifts)"
end

puts
puts "Donor Tiers (lifetime)"
puts "- Major (>= #{format_money(options.major_threshold)}): #{donor_tiers[:major][:count]} donors, #{format_money(donor_tiers[:major][:total])}"
puts "- Mid (>= #{format_money(options.mid_threshold)}): #{donor_tiers[:mid][:count]} donors, #{format_money(donor_tiers[:mid][:total])}"
puts "- Small (< #{format_money(options.mid_threshold)}): #{donor_tiers[:small][:count]} donors, #{format_money(donor_tiers[:small][:total])}"

puts
puts "Stewardship Queue"
stewardship_queue.first(options.queue).each_with_index do |donor, idx|
  label = donor[:name].to_s.strip
  label = donor[:email].to_s.strip if label.empty?
  label = donor[:id].to_s.strip if label.empty?
  label = "Unknown Donor" if label.empty?
  lapsed_flag = donor[:last_gift_date] < lapsed_cutoff ? "lapsed" : "active"
  puts "#{idx + 1}. #{label} - open #{format_money(donor[:open_amount])}, total #{format_money(donor[:total_amount])}, last #{donor[:last_gift_date]} (#{lapsed_flag})"
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
  concentration: {
    top5_total: top5_total,
    top5_share: top5_share,
    top10_total: top10_total,
    top10_share: top10_share,
    largest_donor_total: largest_donor_total,
    largest_donor_share: largest_donor_share
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
  acknowledgements: {
    grace_days: options.ack_days,
    cutoff: ack_cutoff.to_s,
    acknowledged_gifts: acknowledged_gifts.length,
    acknowledged_total: acknowledged_total,
    acknowledged_rate: acknowledged_rate,
    average_days_to_acknowledge: ack_latency_avg,
    median_days_to_acknowledge: ack_latency_median,
    on_time_gifts: on_time_ack.length,
    on_time_rate: on_time_rate,
    unacknowledged_gifts: unacknowledged_gifts.length,
    unacknowledged_total: unacknowledged_total,
    donors: unack_donors_sorted.map do |donor|
      {
        id: donor[:id],
        name: donor[:name],
        email: donor[:email],
        total_amount: donor[:total],
        gift_count: donor[:count],
        last_gift_date: donor[:last_gift_date].to_s
      }
    end
  },
  momentum: {
    window_days: options.recent_days,
    recent_total: recent_total,
    recent_gifts: recent_gifts,
    prior_total: prior_total,
    prior_gifts: prior_gifts,
    delta_total: delta_total,
    delta_gifts: delta_gifts,
    new_donors: new_donors.length,
    reactivated_donors: reactivated_donors.length,
    average_days_between_gifts: avg_interval
  },
  engagement: {
    one_time_donors: one_time_donors.length,
    repeat_donors: repeat_donors.length,
    average_gifts_per_donor: avg_gifts_per_donor
  },
  retention: {
    window_days: 365,
    prior_start: prior_year_start.to_s,
    prior_end: prior_year_end.to_s,
    recent_start: recent_year_start.to_s,
    recent_end: as_of.to_s,
    prior_donors: prior_donors.length,
    recent_donors: recent_donors.length,
    retained_donors: retained_donors.length,
    retention_rate: retention_rate,
    reactivated_donors: reactivated_12m.length,
    churned_donors: churned_12m.length,
    retained_prior_total: retained_prior_total,
    retained_recent_total: retained_recent_total
  },
  recency_buckets: recency_buckets.map do |bucket|
    donor_share = unique_donors.positive? ? bucket[:count].to_f / unique_donors : 0.0
    total_share = total_raised.positive? ? bucket[:total] / total_raised : 0.0
    {
      label: bucket[:label],
      min_days: bucket[:min],
      max_days: bucket[:max],
      donors: bucket[:count],
      total_amount: bucket[:total],
      donor_share: donor_share,
      total_share: total_share
    }
  end,
  monthly_trend: monthly_trend,
  tiers: {
    major_threshold: options.major_threshold,
    mid_threshold: options.mid_threshold,
    major: donor_tiers[:major],
    mid: donor_tiers[:mid],
    small: donor_tiers[:small]
  },
  stewardship_queue: stewardship_queue.first(options.queue).map do |donor|
    {
      id: donor[:id],
      name: donor[:name],
      email: donor[:email],
      total_amount: donor[:total_amount],
      last_gift_date: donor[:last_gift_date].to_s,
      open_amount: donor[:open_amount],
      priority_score: donor[:priority_score],
      lapsed: donor[:last_gift_date] < lapsed_cutoff
    }
  end,
  warnings: warnings
}

if options.json_path
  File.write(options.json_path, JSON.pretty_generate(report))
end

if options.db_sync
  persist_report(
    report,
    options,
    stats,
    report[:top_donors],
    report[:concentration],
    report[:momentum],
    report[:acknowledgements],
    report[:pledges],
    report[:monthly_trend]
  )
  puts
  puts "Report stored in Postgres schema #{options.db_schema}."
end
