# typed: strict
# frozen_string_literal: true

module Authn
  # Roles of machine callers, keyed by Actor issuer and then by exact subject.
  module MachineRoles
    #: type mapping = Hash[String, Hash[String, Array[String]]]

    # Merges a JSON document of the same shape into the base mapping. Raises ArgumentError on a
    # document of another shape, so a broken NET_AID_MACHINE_ROLES fails boot.
    #: (MachineRoles::mapping, String?) -> MachineRoles::mapping
    def self.merge(base, json)
      extra = json.present? ? validate(JSON.parse(json)) : {}

      (base.keys | extra.keys).to_h do |issuer|
        subjects = base.fetch(issuer, {}).merge(extra.fetch(issuer, {})) do |_subject, left, right|
          left | right
        end
        [issuer, subjects.transform_values { it.dup.freeze }.freeze]
      end.freeze
    end

    #: (String issuer, String subject) -> Array[String]
    def self.roles_for(issuer, subject)
      mapping = Rails.configuration.x.authn.machine_roles #: MachineRoles::mapping
      mapping.fetch(issuer, {}).fetch(subject, [])
    end

    #: (untyped) -> MachineRoles::mapping
    private_class_method def self.validate(document)
      valid = document.is_a?(Hash) && document.all? do |issuer, subjects|
        issuer.is_a?(String) && subjects.is_a?(Hash) && subjects.all? do |subject, roles|
          subject.is_a?(String) && roles.is_a?(Array) && roles.all?(String)
        end
      end
      raise ArgumentError, "machine roles must map issuers to subjects to arrays of role names" unless valid

      document
    end
  end
end
