# frozen_string_literal: true

# Helpers shared by database.yml, rake tasks and script/pdsql, loadable without Rails.
module Dsql
  # <id>.dsql.<region>.on.aws, or the PrivateLink form <id>.dsql-<svc>.<region>.on.aws
  HOST_PATTERN = /\A(?<id>[a-z0-9-]+)\.dsql(?:-[a-z0-9]+)?\.(?<region>[a-z0-9-]+)\.on\.aws\z/

  def self.host?(host)
    HOST_PATTERN.match?(host.to_s)
  end

  def self.region_of(host)
    host.to_s.match(HOST_PATTERN)&.[](:region) or raise ArgumentError, "Not a DSQL host: #{host.inspect}"
  end

  # AmazonRootCA1: the container image copy, then the in-repo copy, then libpq's system trust store.
  def self.ssl_root_cert
    @ssl_root_cert ||= [
      "/etc/amazonroot.pem",
      File.expand_path("../data/amazonroot.pem", __dir__)
    ].find { |p| File.exist?(p) } || "system"
  end
end
