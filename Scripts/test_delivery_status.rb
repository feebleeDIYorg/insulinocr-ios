require "tmpdir"
require_relative "../fastlane/lib/insulinocr_delivery_status"

checks = 0
Dir.mktmpdir do |directory|
  path = File.join(directory, "status.json")
  prior = ENV["INSULINOCR_DELIVERY_STATUS_FILE"]
  begin
    ENV["INSULINOCR_DELIVERY_STATUS_FILE"] = path
    raise "Successful result changed" unless InsulinOCRDeliveryStatus.around("apple_key") { 42 } == 42
    raise "Completion missing" unless InsulinOCRDeliveryStatus.read(path) == {"stage" => "apple_key", "code" => "completed"}
    raise "Unsafe file permissions" unless File.stat(path).mode & 0o777 == 0o600
    checks += 1
    {"Couldn't decrypt the repo synthetic-private-password" => "match_decryption_failed",
     "No matching provisioning profiles synthetic-private-app" => "match_profile_missing",
     "Unauthorized synthetic-private-key" => "match_apple_auth_failed",
     "synthetic-private-unknown" => "match_failed"}.each do |message, code|
      begin
        InsulinOCRDeliveryStatus.around("match") { raise message }
        raise "Expected failure"
      rescue RuntimeError => error
        raise "Exception changed" unless error.message == message
      end
      raise "Wrong failure stage" unless InsulinOCRDeliveryStatus.read(path) == {"stage" => "match", "code" => code}
      raise "Private error leaked" if File.read(path).include?("synthetic-private")
      checks += 1
    end
    File.write(path, JSON.generate({stage: "match", code: "match_failed", raw: "synthetic-private-canary"}))
    raise "Extra fields leaked" unless InsulinOCRDeliveryStatus.read(path).keys.sort == %w[code stage]
    checks += 1
    File.write(path, JSON.generate({stage: "synthetic-private-stage", code: "synthetic-private-code"}))
    raise "Untrusted status leaked" unless InsulinOCRDeliveryStatus.read(path)["code"] == "status_unavailable"
    checks += 1
    File.write(path, "malformed synthetic-private-status")
    raise "Malformed status accepted" unless InsulinOCRDeliveryStatus.read(path)["code"] == "status_unavailable"
    checks += 1
    File.unlink(path)
    target = File.join(directory, "unchanged")
    File.write(target, "unchanged")
    File.symlink(target, path)
    begin
      InsulinOCRDeliveryStatus.record("match", "in_progress")
      raise "Symlink accepted"
    rescue ArgumentError
      raise "Target modified" unless File.read(target) == "unchanged"
    end
    checks += 1
  ensure
    prior ? ENV["INSULINOCR_DELIVERY_STATUS_FILE"] = prior : ENV.delete("INSULINOCR_DELIVERY_STATUS_FILE")
  end
end
puts "Delivery status: #{checks} privacy and failure-path checks passed (synthetic; no network)."
