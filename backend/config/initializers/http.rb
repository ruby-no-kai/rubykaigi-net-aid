# typed: strict
# frozen_string_literal: true

Rails.application.configure do
  # Sent on every outbound request, so issuers can tell this app's fetches apart.
  config.x.http.user_agent = "rubykaigi-net-aid (+https://github.com/ruby-no-kai/rubykaigi-net-aid)"
end
