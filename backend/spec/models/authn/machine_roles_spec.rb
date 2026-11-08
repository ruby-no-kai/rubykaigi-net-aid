# frozen_string_literal: true

require "rails_helper"

RSpec.describe Authn::MachineRoles, type: :model do
  describe ".merge" do
    let(:base) { {"github-actions" => {"repo:a/b:ref:refs/heads/main" => %w[exporter]}, "aws-iam" => {}} }

    it "keeps the base mapping without a document" do
      expect(described_class.merge(base, nil)).to eq(base)
    end

    it "adds subjects and issuers from the document, uniting the roles of a subject in both" do
      json = JSON.generate(
        "github-actions" => {"repo:a/b:ref:refs/heads/main" => %w[operator exporter], "repo:a/c:environment:prd" => %w[operator]},
        "aws-iam" => {"arn:aws:iam::1:role/r" => %w[operator]},
      )

      expect(described_class.merge(base, json)).to eq(
        "github-actions" => {
          "repo:a/b:ref:refs/heads/main" => %w[exporter operator],
          "repo:a/c:environment:prd" => %w[operator]
        },
        "aws-iam" => {"arn:aws:iam::1:role/r" => %w[operator]},
      )
    end

    it "refuses a document of another shape" do
      expect { described_class.merge(base, JSON.generate("aws-iam" => {"arn" => "operator"})) }.to raise_error(ArgumentError)
    end

    it "refuses a document that is not JSON" do
      expect { described_class.merge(base, "{") }.to raise_error(JSON::ParserError)
    end
  end

  describe ".roles_for" do
    it "matches the subject exactly" do
      with_machine_roles("aws-iam" => {"arn:aws:iam::1:role/r" => %w[operator]}) do
        expect(described_class.roles_for("aws-iam", "arn:aws:iam::1:role/r")).to eq(%w[operator])
        expect(described_class.roles_for("aws-iam", "arn:aws:iam::1:role/r2")).to eq([])
        expect(described_class.roles_for("github-actions", "arn:aws:iam::1:role/r")).to eq([])
      end
    end
  end
end
