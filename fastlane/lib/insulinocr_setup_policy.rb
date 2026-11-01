require "time"

module InsulinOCRSetupPolicy
  LANES = {"validate" => "validate_secrets", "identifiers" => "identifiers",
    "profiles_check" => "check_profiles", "profiles_apply" => "prepare_profiles",
    "preflight" => "signing_preflight", "qa_upload" => "beta", "upload" => "beta"}.freeze

  QA_NOTICE = "Experimenteller interner QA-Build. OCR-, Geräte- und Leistungsabnahme sind noch offen. Nur für Tests und Feedback, nicht für Therapieentscheidungen.".freeze

  def self.lane(mode)
    LANES.fetch(mode) { raise ArgumentError, "Unsupported delivery operation" }
  end

  def self.upload_mode?(mode)
    %w[qa_upload upload].include?(mode)
  end

  def self.upload_authorized?(env, event)
    mode = env["INSULINOCR_DELIVERY_MODE"]
    sha = env["GITHUB_SHA"]
    repository = env["GITHUB_REPOSITORY"]
    upload_mode?(mode) && sha.to_s.match?(/\A[a-f0-9]{40}\z/) &&
      env["INSULINOCR_VERIFIED_CI_HEAD"] == sha &&
      repository.to_s.match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}) &&
      env["GITHUB_REF"] == "refs/heads/main" && env["GITHUB_EVENT_NAME"] == "workflow_dispatch" &&
      env["GITHUB_WORKFLOW_REF"] == "#{repository}/.github/workflows/testflight.yml@refs/heads/main" &&
      event.is_a?(Hash) && event["inputs"].is_a?(Hash) &&
      event.dig("inputs", "mode") == mode &&
      (mode == "qa_upload" || env["INSULINOCR_RELEASE_GATES_CONFIRMED"] == "true")
  end

  def self.release_notes(mode, notes)
    mode == "qa_upload" ? "#{QA_NOTICE}\n\n#{notes}" : notes
  end

  def self.existing_certificate_id(tree)
    raise ArgumentError, "Incomplete signing inventory" if tree["truncated"]
    files = tree.fetch("tree").select { |entry| entry["type"] == "blob" }.map { |entry| entry.fetch("path") }
    pairs = files.filter_map do |file|
      match = file.match(%r{\Acerts/distribution/([A-Za-z0-9_-]+)\.cer\z})
      match[1] if match && files.include?("certs/distribution/#{match[1]}.p12")
    end
    raise ArgumentError, "One existing certificate and private key are required" unless pairs.length == 1
    pairs.first
  end

  def self.profile_mapping(identifiers, mapping)
    raise ArgumentError, "Missing selected provisioning profiles" unless mapping.is_a?(Hash)
    identifiers.to_h do |identifier|
      name = mapping[identifier]
      raise ArgumentError, "Missing selected provisioning profile" unless name.is_a?(String) && !name.strip.empty? && !name.match?(/[\r\n\0]/)
      [identifier, name]
    end
  end

  def self.profile_creation_authorized?(env, event)
    env["INSULINOCR_DELIVERY_MODE"] == "profiles_apply" &&
      env["GITHUB_REF"] == "refs/heads/main" && env["GITHUB_EVENT_NAME"] == "workflow_dispatch" &&
      env["GITHUB_WORKFLOW_REF"].to_s.end_with?("/.github/workflows/create_profiles.yml@refs/heads/main") &&
      event.dig("inputs", "mode") == "prepare_profiles"
  end

  # Match may prepare the two app profiles, but must never replace a certificate.
  module ExistingCertificateOnly
    def generate_certificate(*)
      raise ArgumentError, "Certificate creation is disabled"
    end
  end
end
