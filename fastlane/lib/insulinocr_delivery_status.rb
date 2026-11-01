require "json"

# Only these fixed tokens may cross the private signing-log boundary.
module InsulinOCRDeliveryStatus
  STAGES = %w[dispatch configuration credentials repository_access project_generation apple_key apple_access identifiers profiles keychain match app_store_build_number archive upload].freeze
  CODES = %w[in_progress completed dispatch_invalid configuration_invalid credentials_invalid repository_access_failed project_generation_failed apple_key_invalid apple_access_failed identifiers_failed profiles_failed keychain_failed match_decryption_failed match_profile_missing match_apple_auth_failed match_failed app_store_build_number_failed archive_failed upload_failed process_failed status_unavailable].freeze

  def self.record(stage, code, env: ENV)
    raise ArgumentError, "Invalid diagnostic token" unless STAGES.include?(stage) && CODES.include?(code)
    path = env["INSULINOCR_DELIVERY_STATUS_FILE"]
    return unless path
    raise ArgumentError, "Unsafe diagnostic path" if File.symlink?(path)
    File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
      file.write(JSON.generate({stage: stage, code: code}))
    end
    File.chmod(0o600, path)
  end

  def self.failure_code(stage, error)
    if stage == "match"
      # Inspect locally; never return or persist any substring of an exception.
      message = error.message.to_s
      return "match_decryption_failed" if message.match?(/decrypt|invalid password|bad decrypt|wrong final block/i)
      return "match_profile_missing" if message.match?(/no matching|could not find.*(?:profile|certificate)|couldn't find.*(?:profile|certificate)|no code signing identity/i)
      return "match_apple_auth_failed" if message.match?(/unauthori[sz]ed|authentication|invalid.*token|access forbidden/i)
      return "match_failed"
    end
    {"dispatch" => "dispatch_invalid", "configuration" => "configuration_invalid",
     "credentials" => "credentials_invalid", "repository_access" => "repository_access_failed",
     "apple_key" => "apple_key_invalid", "keychain" => "keychain_failed"}.fetch(stage, "#{stage}_failed")
  end

  def self.around(stage)
    record(stage, "in_progress")
    result = yield
    record(stage, "completed")
    result
  rescue StandardError => error
    record(stage, failure_code(stage, error))
    raise
  end

  def self.read(path)
    result = JSON.parse(File.read(path))
    return {"stage" => result["stage"], "code" => result["code"]} if STAGES.include?(result["stage"]) && CODES.include?(result["code"])
    {"stage" => "dispatch", "code" => "status_unavailable"}
  rescue StandardError
    {"stage" => "dispatch", "code" => "status_unavailable"}
  end
end
