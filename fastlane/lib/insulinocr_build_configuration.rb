require "json"
require "fileutils"

module InsulinOCRBuildConfiguration
  FIELDS = %w[app_identifier share_identifier app_group cloudkit_container match_git_url].freeze
  SETTINGS = {"app_identifier" => "INSULINOCR_APP_IDENTIFIER", "app_group" => "INSULINOCR_APP_GROUP", "cloudkit_container" => "INSULINOCR_CLOUDKIT_CONTAINER"}.freeze

  def self.parse(raw, team)
    config = JSON.parse(raw)
    raise ArgumentError, "Invalid build configuration fields" unless config.is_a?(Hash) && config.keys.sort == FIELDS.sort
    raise ArgumentError, "Invalid Apple team configuration" unless team.to_s.match?(/\A[A-Z0-9]{10}\z/) && team != "SIMULATOR1"
    FIELDS.each { |field| raise ArgumentError, "Missing build configuration field: #{field}" unless config[field].is_a?(String) && !config[field].empty? }
    %w[app_identifier share_identifier app_group cloudkit_container].each do |field|
      raise ArgumentError, "Invalid identifier field: #{field}" unless config[field].match?(/\A[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\z/)
    end
    raise ArgumentError, "Inconsistent share identifier" unless config["share_identifier"] == "#{config['app_identifier']}.share"
    raise ArgumentError, "Invalid app group" unless config["app_group"].start_with?("group.")
    raise ArgumentError, "Invalid CloudKit container" unless config["cloudkit_container"].start_with?("iCloud.")
    raise ArgumentError, "Example identifiers cannot be signed" if config.values.any? { |v| v.include?("org.example") }
    raise ArgumentError, "Invalid Match URL" unless config["match_git_url"].match?(/\Ahttps:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\.git\z/)
    config
  rescue JSON::ParserError
    raise ArgumentError, "Invalid build configuration JSON"
  end

  def self.prepare(root, signing:, env: ENV)
    path = File.join(root, "Config/Local.generated.xcconfig")
    raise ArgumentError, "Unsafe generated configuration path" if File.symlink?(path)
    unless signing
      FileUtils.rm_f(path)
      return
    end
    raw = env["INSULINOCR_BUILD_CONFIG"]
    raw ||= File.read(env.fetch("INSULINOCR_BUILD_CONFIG_FILE")) if env["INSULINOCR_BUILD_CONFIG_FILE"]
    raise ArgumentError, "Private build configuration is unavailable" unless raw
    team = env.fetch("TEAMID", env["APPLE_TEAM_ID"])
    config = parse(raw, team)
    values = SETTINGS.map { |field, setting| "#{setting} = #{config.fetch(field)}" }
    values << "APPLE_TEAM_ID = #{team}"
    File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(values.join("\n") + "\n") }
    File.chmod(0o600, path)
    env["APP_IDENTIFIER"] = config.fetch("app_identifier")
    env["MATCH_GIT_URL"] = config.fetch("match_git_url")
    env["APPLE_TEAM_ID"] = team
    config
  end
end
