class ApplicationRecord < ActiveRecord::Base
  include DsqlTransactionable
  include TypeidRails::AssociationSupport

  primary_abstract_class
end
