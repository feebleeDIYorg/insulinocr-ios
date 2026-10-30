#!/usr/bin/env ruby
# All detailed signing output stays on the ephemeral runner, never in Actions logs.
require "json"
require "base64"
require "net/http"
require "tmpdir"
require_relative "../fastlane/lib/insulinocr_build_configuration"
require_relative "../fastlane/lib/insulinocr_credentials"

root = File.expand_path("..", __dir__)
exit_code = 1
begin
  raise ArgumentError, "Main branch required" unless ENV["GITHUB_REF"] == "refs/heads/main"
  raise ArgumentError, "Manual dispatch required" unless ENV["GITHUB_EVENT_NAME"] == "workflow_dispatch"
  mode = ENV.fetch("INSULINOCR_DELIVERY_MODE", "preflight")
  raise ArgumentError, "Invalid delivery mode" unless %w[preflight upload].include?(mode)
  config = InsulinOCRBuildConfiguration.parse(ENV.fetch("INSULINOCR_BUILD_CONFIG"), ENV.fetch("TEAMID"))
  config.values.each { |value| puts "::add-mask::#{value}" }
  puts "::add-mask::#{ENV.fetch('TEAMID')}"
  %w[GH_PAT MATCH_PASSWORD].each { |key| raise ArgumentError, "Credential unavailable" if ENV.fetch(key).empty? }
  InsulinOCRCredentials.apple_api_key_options(ENV)
  token = ENV.fetch("GH_PAT")
  repository = config.fetch("match_git_url").delete_prefix("https://github.com/").delete_suffix(".git")
  uri = URI("https://api.github.com/repos/#{repository}")
  request = Net::HTTP::Get.new(uri)
  request["Authorization"] = "Bearer #{token}"
  request["Accept"] = "application/vnd.github+json"
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) { |http| http.request(request) }
  raise ArgumentError, "Signing repository access unavailable" unless response.code == "200"
  metadata = JSON.parse(response.body)
  raise ArgumentError, "Private signing repository required" unless metadata["private"] == true && metadata.dig("permissions", "pull") == true
  ENV["MATCH_GIT_BASIC_AUTHORIZATION"] = Base64.strict_encode64("x-access-token:#{token}")
  puts "::add-mask::#{ENV.fetch('MATCH_GIT_BASIC_AUTHORIZATION')}"
  $stdout.flush
  Dir.mktmpdir("insulinocr-signing-", ENV.fetch("RUNNER_TEMP")) do |directory|
    log_path = File.join(directory, "signing.log")
    File.open(log_path, "w", 0o600) do |log|
      lane = mode == "preflight" ? "signing_preflight" : "beta"
      success = system("bundle", "exec", "fastlane", "ios", lane, "tests_completed:true", chdir: root, out: log, err: log)
      exit_code = success ? 0 : 1
    end
  end
  puts(exit_code.zero? ? (mode == "preflight" ? "Read-only signing preflight completed; no build uploaded." : "TestFlight upload completed.") : "::error::Signing or upload failed. No private diagnostics were published; signing credentials and Match compatibility must be checked privately.")
rescue StandardError
  puts "::error::Private signing preflight failed. No signing data was changed or published."
ensure
  FileUtils.rm_f(File.join(root, "Config/Local.generated.xcconfig"))
  FileUtils.rm_rf(File.join(root, "build")) if ENV["CI"] == "true" && ENV["GITHUB_ACTIONS"] == "true"
end
exit(exit_code)
