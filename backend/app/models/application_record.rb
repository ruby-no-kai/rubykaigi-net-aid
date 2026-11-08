# frozen_string_literal: true
# typed: strict

require "protobufable/column_validatable"

class ApplicationRecord < ActiveRecord::Base
  include DsqlTransactionable
  include TypeidRails::AssociationSupport
  include Protobufable::ColumnValidatable

  primary_abstract_class
end
