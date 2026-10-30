# Credential families have different content encodings. Never combine IDs from
# one family with a private key from the other.
module InsulinOCRCredentials
  PROJECT_KEYS = %w[ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_CONTENT_BASE64].freeze
  ORGANIZATION_KEYS = %w[FASTLANE_KEY_ID FASTLANE_ISSUER_ID FASTLANE_KEY].freeze

  def self.apple_api_key_options(environment)
    present = ->(name) { !environment[name].to_s.strip.empty? }
    names = PROJECT_KEYS.any?(&present) ? PROJECT_KEYS : ORGANIZATION_KEYS
    missing = names.reject(&present)
    unless missing.empty?
      raise ArgumentError,
        "Configure one complete Apple credential family (ASC_* or FASTLANE_*). Missing: #{missing.join(', ')}. " \
        "Existing organization secrets must be accessible to this repository."
    end
    {
      key_id: environment.fetch(names[0]).strip,
      issuer_id: environment.fetch(names[1]).strip,
      key_content: environment.fetch(names[2]),
      is_key_content_base64: names.equal?(PROJECT_KEYS),
      in_house: false
    }
  end
end
