require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

# Exercise the real entry point in an isolated source tree, without credentials.
checks = 0
source = File.expand_path("..", __dir__)
Dir.mktmpdir("insulinocr-dispatch-test-") do |root|
  FileUtils.mkdir_p(File.join(root, "Scripts"))
  FileUtils.mkdir_p(File.join(root, "fastlane/lib"))
  FileUtils.cp(File.join(source, "Scripts/run_testflight.rb"), File.join(root, "Scripts"))
  %w[build_configuration credentials delivery_status setup_policy].each do |name|
    FileUtils.cp(File.join(source, "fastlane/lib/insulinocr_#{name}.rb"), File.join(root, "fastlane/lib"))
  end
  sha = "a" * 40
  base = {"RUBYLIB" => $LOAD_PATH.join(File::PATH_SEPARATOR), "GITHUB_REF" => "refs/heads/main", "GITHUB_EVENT_NAME" => "workflow_dispatch",
    "GITHUB_SHA" => sha, "INSULINOCR_VERIFIED_CI_HEAD" => sha,
    "INSULINOCR_DELIVERY_MODE" => "upload", "INSULINOCR_BUILD_CONFIG" => "synthetic-private-canary"}
  cases = [
    [base.merge("INSULINOCR_RELEASE_GATES_CONFIRMED" => "false"), "release_acceptance_required"],
    [base, "release_acceptance_required"],
    [base.merge("INSULINOCR_RELEASE_GATES_CONFIRMED" => "true", "INSULINOCR_VERIFIED_CI_HEAD" => "b" * 40), "dispatch_invalid"],
    [base.merge("INSULINOCR_RELEASE_GATES_CONFIRMED" => "true"), "configuration_invalid"],
    [base.merge("INSULINOCR_DELIVERY_MODE" => "preflight", "INSULINOCR_RELEASE_GATES_CONFIRMED" => "false"), "configuration_invalid"]
  ]
  cases.each do |env, code|
    out, err, status = Open3.capture3(env, RbConfig.ruby, File.join(root, "Scripts/run_testflight.rb"), unsetenv_others: true)
    raise "Unexpected dispatch result" unless !status.success? && out.include?("code=#{code}.") && err.empty?
    raise "Private input leaked" if out.include?("synthetic-private-canary")
    raise "Missing actionable acceptance message" if code == "release_acceptance_required" && !out.include?("release_gates_confirmed must explicitly be true")
    checks += 1
  end
end
puts "Delivery dispatch: #{checks} isolated entry-point checks passed (synthetic; no network)."
