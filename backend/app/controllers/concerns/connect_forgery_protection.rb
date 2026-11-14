# typed: strict
# frozen_string_literal: true

# Rejects a Connect call that another site's page could have made a browser send with the viewer's
# cookies.
#
# A POST must carry Connect-Protocol-Version, which a page on another origin can set only after a
# CORS preflight that this app never grants. A GET needs no header, as connect_rpc_rails serves GET
# only for RPCs declared free of side effects. Sec-Fetch-Site and Origin, which browsers send, must
# name this origin when present.
#
# @requires_ancestor: ActionController::API
module ConnectForgeryProtection
  extend ActiveSupport::Concern

  # A page on another site or origin sent the request, which may carry the viewer's cookies without
  # their intent.
  class BlockedRequestError < Errors::PermissionDenied; end

  # Sec-Fetch-Site values of a request this site's own pages made, or the viewer made directly.
  ALLOWED_FETCH_SITES = [ "same-origin", "none" ].freeze #: Array[String]

  included do
    before_action :verify_connect_request_origin!
  end

  #: () -> void
  private def verify_connect_request_origin!
    if request.post? && request.headers["Connect-Protocol-Version"] != "1"
      log_connect_request_refusal(:missing_connect_protocol_version)
      # Answered as Connect's own protocol error, the same one connect-go sends.
      raise ConnectRpcRails::Error.new(:invalid_argument, 'missing required header: set Connect-Protocol-Version to "1"')
    end

    fetch_site = request.headers["Sec-Fetch-Site"]
    if fetch_site && !ALLOWED_FETCH_SITES.include?(fetch_site)
      log_connect_request_refusal(:cross_site, fetch_site:)
      raise BlockedRequestError.new(detail: "The request came from another site (Sec-Fetch-Site: #{fetch_site}).")
    end

    origin = request.headers["Origin"]
    if origin && origin != request.base_url
      log_connect_request_refusal(:cross_origin, origin:)
      raise BlockedRequestError.new(detail: "The request came from another origin (Origin: #{origin}).")
    end
  end

  #: (Symbol, **String) -> void
  private def log_connect_request_refusal(reason, **headers)
    # TODO: pass these as a payload once rails_semantic_logger lands (specs/021); Logger takes none.
    fields = { reason:, **headers }.map { |key, value| "#{key}=#{value.inspect}" }.join(" ")
    logger.warn("Refused a Connect request that may be forged: #{fields}")
  end
end
