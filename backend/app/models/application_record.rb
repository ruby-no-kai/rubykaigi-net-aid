class ApplicationRecord < ActiveRecord::Base
  include DsqlTransactionable

  primary_abstract_class
end
