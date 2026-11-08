# frozen_string_literal: true

require "rubocop"
require "rubocop/rspec/support"
require_relative "../../../../rubocop/changelog_bulk_write"

RSpec.describe RuboCop::Cop::Changelog::BulkWrite, :config do
  include RuboCop::RSpec::ExpectOffense

  %w[
    insert_all upsert_all update_all delete_all delete_by update_column update_columns update_counters
    increment! decrement! insert_all!
  ].each do |method|
    it "flags #{method}" do
      expect_offense(<<~RUBY, method:)
        Site.on(branch).#{method}(rows)
                        ^{method} `#{method}` skips the changelog; use Changelog.current.insert_all! or a save per row.
      RUBY
    end
  end

  %w[insert insert! upsert].each do |method|
    it "flags #{method} of a row" do
      expect_offense(<<~RUBY, method:)
        Site.#{method}(name: "x")
             ^{method} `#{method}` skips the changelog; use Changelog.current.insert_all! or a save per row.
      RUBY
    end
  end

  it "flags a record's touch and delete" do
    expect_offense(<<~RUBY)
      site.touch
           ^^^^^ `touch` skips the changelog; use Changelog.current.insert_all! or a save per row.
      site.delete
           ^^^^^^ `delete` skips the changelog; use Changelog.current.insert_all! or a save per row.
    RUBY
  end

  it "flags a safe-navigation call" do
    expect_offense(<<~RUBY)
      site&.update_columns(name: "x")
            ^^^^^^^^^^^^^^ `update_columns` skips the changelog; use Changelog.current.insert_all! or a save per row.
    RUBY
  end

  it "accepts the changelog's own bulk insert and ordinary saves" do
    expect_no_offenses(<<~RUBY)
      Changelog.current.insert_all!(scans)
      site.update!(name: "x")
      site.destroy!
    RUBY
  end

  it "accepts the same names on arrays, strings, hashes and files" do
    expect_no_offenses(<<~RUBY)
      list.insert(0, item)
      name.insert(2, "-")
      params.delete(:id)
      FileUtils.touch(path)
    RUBY
  end
end
