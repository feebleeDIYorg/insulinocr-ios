#!/usr/bin/env ruby
require "base64"
require "openssl"
require_relative "../fastlane/lib/insulinocr_credentials"

def verify(condition, message)
  raise message unless condition
end

def rejects(environment, names)
  begin
    InsulinOCRCredentials.apple_api_key_options(environment)
  rescue ArgumentError => error
    verify(names.all? { |name| error.message.include?(name) }, "Missing credential names were not reported")
    verify(!error.message.include?("synthetic-secret"), "Credential value leaked into an error")
    return
  end
  raise "Incomplete credentials were accepted"
end

# Ephemeral synthetic material only; it has no account, permissions or issuer.
pem = OpenSSL::PKey::EC.generate("prime256v1").private_to_pem
legacy = {"FASTLANE_KEY_ID" => "SYNTHETIC1", "FASTLANE_ISSUER_ID" => "synthetic-issuer",
          "FASTLANE_KEY" => pem}
project = {"ASC_KEY_ID" => "SYNTHETIC2", "ASC_ISSUER_ID" => "other-issuer",
           "ASC_KEY_CONTENT_BASE64" => Base64.strict_encode64(pem)}
raw = InsulinOCRCredentials.apple_api_key_options(legacy)
verify(!raw[:is_key_content_base64] && OpenSSL::PKey.read(raw[:key_content]).private?, "Existing raw key contract changed")
encoded = InsulinOCRCredentials.apple_api_key_options(project)
verify(encoded[:is_key_content_base64] &&
       OpenSSL::PKey.read(Base64.strict_decode64(encoded[:key_content])).private?, "Base64 key contract changed")
both = InsulinOCRCredentials.apple_api_key_options(legacy.merge(project))
verify(both == encoded, "Explicit project credentials did not take precedence")
blank_project = project.transform_values { " " }
verify(InsulinOCRCredentials.apple_api_key_options(legacy.merge(blank_project)) == raw, "Empty secret bindings prevented reuse")
rejects(legacy.merge("ASC_KEY_ID" => "synthetic-secret"), %w[ASC_ISSUER_ID ASC_KEY_CONTENT_BASE64])
rejects({"FASTLANE_KEY_ID" => "synthetic-secret"}, %w[FASTLANE_ISSUER_ID FASTLANE_KEY])
rejects({}, InsulinOCRCredentials::ORGANIZATION_KEYS)
verify(raw[:in_house] == false && encoded[:in_house] == false, "Unexpected enterprise account mode")
puts "Fastlane credential compatibility: 8 checks passed (synthetic keys; no network)."
