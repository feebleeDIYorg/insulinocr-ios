
require "tmpdir"
require_relative "../fastlane/lib/insulinocr_build_configuration"

class BuildConfigurationTests
  def assert_equal(expected, actual)
    raise "Unexpected result" unless expected == actual
  end
  def assert_includes(value, expected)
    raise "Missing expected value" unless value.include?(expected)
  end
  def refute(value)
    raise "Unexpected truthy result" if value
  end
  def assert_raises(type)
    begin
      yield
    rescue type
      return
    end
    raise "Expected validation failure"
  end
  def config
    {"app_identifier" => "test.synthetic.insulinocr", "share_identifier" => "test.synthetic.insulinocr.share", "app_group" => "group.test.synthetic.insulinocr", "cloudkit_container" => "iCloud.test.synthetic.insulinocr", "match_git_url" => "https://github.com/synthetic/signing.git"}
  end

  def parse(value = config, team = "SYNTHETIC1")
    InsulinOCRBuildConfiguration.parse(JSON.generate(value), team)
  end

  def test_valid_configuration
    assert_equal config, parse
  end

  def test_rejects_missing_and_unexpected_fields
    assert_raises(ArgumentError) { parse(config.reject { |key, _| key == "app_group" }) }
    assert_raises(ArgumentError) { parse(config.merge("token" => "synthetic")) }
  end

  def test_rejects_example_team_and_inconsistent_extension
    assert_raises(ArgumentError) { parse(config, "SIMULATOR1") }
    assert_raises(ArgumentError) { parse(config.merge("share_identifier" => "test.other.share")) }
  end

  def test_rejects_injected_settings_and_credential_urls
    assert_raises(ArgumentError) { parse(config.merge("app_group" => "group.test\nOTHER = value")) }
    assert_raises(ArgumentError) { parse(config.merge("match_git_url" => "https://user:password@github.com/synthetic/signing.git")) }
  end

  def test_rejects_unsigned_examples_and_malformed_json
    assert_raises(ArgumentError) { parse(config.merge("cloudkit_container" => "iCloud.org.example.insulinocr")) }
    assert_raises(ArgumentError) { InsulinOCRBuildConfiguration.parse("invalid", "SYNTHETIC1") }
  end

  def test_generates_private_override_and_resets_simulator_defaults
    Dir.mktmpdir do |root|
      Dir.mkdir(File.join(root, "Config"))
      env = {"INSULINOCR_BUILD_CONFIG" => JSON.generate(config), "TEAMID" => "SYNTHETIC1"}
      InsulinOCRBuildConfiguration.prepare(root, signing: true, env: env)
      file = File.join(root, "Config/Local.generated.xcconfig")
      assert_equal 0o600, File.stat(file).mode & 0o777
      assert_includes File.read(file), "INSULINOCR_APP_GROUP = group.test.synthetic.insulinocr"
      assert_equal config["app_identifier"], env["APP_IDENTIFIER"]
      InsulinOCRBuildConfiguration.prepare(root, signing: false, env: env)
      refute File.exist?(file)
    end
  end
end

tests = BuildConfigurationTests.new
checks = tests.public_methods.grep(/^test_/)
checks.each { |check| tests.public_send(check) }
puts "Build configuration: #{checks.length} checks passed (synthetic values; no network)."
