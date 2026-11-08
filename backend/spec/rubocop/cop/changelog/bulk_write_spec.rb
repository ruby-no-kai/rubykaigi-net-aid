# frozen_string_literal: true

require "rubocop"
require "rubocop/rspec/support"
require_relative "../../../../rubocop/changelog_bulk_write"

RSpec.describe RuboCop::Cop::Changelog::BulkWrite, :config do
  include RuboCop::RSpec::ExpectOffense

  %w[insert_all upsert_all update_all delete_all update_column update_columns].each do |method|
    it "flags #{method}" do
      expect_offense(<<~RUBY, method:)
        Site.on(branch).#{method}(rows)
                        ^{method} `#{method}` skips the changelog; use Changelog.current.insert_all! or a save per row.
      RUBY
    end
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
end
