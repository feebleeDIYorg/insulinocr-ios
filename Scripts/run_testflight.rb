#!/usr/bin/env ruby
# Detailed output is temporary and private. Public output contains allowlisted tokens only.
require "base64"
require "net/http"
require "tmpdir"
require_relative "../fastlane/lib/insulinocr_build_configuration"
require_relative "../fastlane/lib/insulinocr_credentials"
require_relative "../fastlane/lib/insulinocr_delivery_status"
require_relative "../fastlane/lib/insulinocr_setup_policy"

root = File.expand_path("..", __dir__)
exit_code = 1
stage = "dispatch"
begin
  raise ArgumentError unless ENV["GITHUB_REF"] == "refs/heads/main" && ENV["GITHUB_EVENT_NAME"] == "workflow_dispatch"
  mode = ENV.fetch("INSULINOCR_DELIVERY_MODE", "preflight")
  lane = InsulinOCRSetupPolicy.lane(mode)
  if mode == "profiles_apply"
    event = JSON.parse(File.read(ENV.fetch("GITHUB_EVENT_PATH")))
    raise ArgumentError unless InsulinOCRSetupPolicy.profile_creation_authorized?(ENV, event)
  end
  if InsulinOCRSetupPolicy.upload_mode?(mode)
    raise ArgumentError unless ENV["INSULINOCR_VERIFIED_CI_HEAD"] == ENV.fetch("GITHUB_SHA")
    if mode == "upload"
      stage = "release_acceptance"
      raise ArgumentError unless ENV["INSULINOCR_RELEASE_GATES_CONFIRMED"] == "true"
    end
    stage = "dispatch"
    event = JSON.parse(File.read(ENV.fetch("GITHUB_EVENT_PATH")))
    raise ArgumentError unless InsulinOCRSetupPolicy.upload_authorized?(ENV, event)
  end
  stage = "configuration"
  config = InsulinOCRBuildConfiguration.parse(ENV.fetch("INSULINOCR_BUILD_CONFIG"), ENV.fetch("TEAMID"))
  config.values.each { |value| puts "::add-mask::#{value}" }
  puts "::add-mask::#{ENV.fetch('TEAMID')}"
  stage = "credentials"
  %w[GH_PAT MATCH_PASSWORD].each { |key| raise ArgumentError if ENV.fetch(key).empty? }
  InsulinOCRCredentials.apple_api_key_options(ENV)
  stage = "repository_access"
  token = ENV.fetch("GH_PAT")
  repository = config.fetch("match_git_url").delete_prefix("https://github.com/").delete_suffix(".git")
  uri = URI("https://api.github.com/repos/#{repository}")
  request = Net::HTTP::Get.new(uri)
  request["Authorization"] = "Bearer #{token}"
  request["Accept"] = "application/vnd.github+json"
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) { |http| http.request(request) }
  raise ArgumentError unless response.code == "200"
  metadata = JSON.parse(response.body)
  raise ArgumentError unless metadata["private"] == true && metadata.dig("permissions", "pull") == true
  raise ArgumentError if mode == "profiles_apply" && metadata.dig("permissions", "push") != true
  branch = config.fetch("match_git_branch", "main")
  tree_uri = URI("https://api.github.com/repos/#{repository}/git/trees/#{URI.encode_www_form_component(branch)}?recursive=1")
  tree_request = Net::HTTP::Get.new(tree_uri)
  tree_request["Authorization"] = "Bearer #{token}"
  tree_request["Accept"] = "application/vnd.github+json"
  tree_response = Net::HTTP.start(tree_uri.host, tree_uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) { |http| http.request(tree_request) }
  raise ArgumentError unless tree_response.code == "200"
  ENV["INSULINOCR_EXISTING_CERTIFICATE_ID"] = InsulinOCRSetupPolicy.existing_certificate_id(JSON.parse(tree_response.body))
  puts "::add-mask::#{ENV.fetch('INSULINOCR_EXISTING_CERTIFICATE_ID')}"
  ENV["MATCH_GIT_BASIC_AUTHORIZATION"] = Base64.strict_encode64("x-access-token:#{token}")
  puts "::add-mask::#{ENV.fetch('MATCH_GIT_BASIC_AUTHORIZATION')}"
  $stdout.flush
  Dir.mktmpdir("insulinocr-signing-", ENV.fetch("RUNNER_TEMP")) do |directory|
    status_path = File.join(directory, "status.json")
    ENV["INSULINOCR_DELIVERY_STATUS_FILE"] = status_path
    InsulinOCRDeliveryStatus.record("dispatch", "in_progress")
    File.open(File.join(directory, "signing.log"), "w", 0o600) do |log|
      success = system("bundle", "exec", "fastlane", "ios", lane, "tests_completed:true", chdir: root, out: log, err: log)
      exit_code = success ? 0 : 1
    end
    unless exit_code.zero?
      status = InsulinOCRDeliveryStatus.read(status_path)
      code = %w[in_progress completed].include?(status["code"]) ? "process_failed" : status["code"]
      puts "::error::InsulinOCR delivery failed: stage=#{status['stage']} code=#{code}. Private diagnostics were not published."
    end
  end
  puts(InsulinOCRSetupPolicy.upload_mode?(mode) ? "TestFlight upload completed." : "Requested delivery stage completed; no build uploaded.") if exit_code.zero?
rescue StandardError => error
  puts "::error::InsulinOCR delivery failed: stage=#{stage} code=#{InsulinOCRDeliveryStatus.failure_code(stage, error)}. Private diagnostics were not published."
  if stage == "release_acceptance"
    puts "::error::Upload was not started: release_gates_confirmed must explicitly be true after the documented release criteria pass. Use preflight for a read-only signing check."
  end
ensure
  ENV.delete("INSULINOCR_DELIVERY_STATUS_FILE")
  FileUtils.rm_f(File.join(root, "Config/Local.generated.xcconfig"))
  FileUtils.rm_rf(File.join(root, "build")) if ENV["CI"] == "true" && ENV["GITHUB_ACTIONS"] == "true"
end
exit(exit_code)
