require_relative "../fastlane/lib/insulinocr_setup_policy"
checks = 0
assert = ->(value) { raise "Setup policy check failed" unless value }
reject = ->(&block) { begin; block.call; rescue ArgumentError; next; end; raise "Expected safe rejection" }
files = ->(paths) { {"tree" => paths.map { |path| {"type" => "blob", "path" => path} }, "truncated" => false} }
valid = files.call(%w[certs/distribution/SYNTHETIC1.cer certs/distribution/SYNTHETIC1.p12 profiles/appstore/AppStore_test.app.mobileprovision])
assert.call(InsulinOCRSetupPolicy.existing_certificate_id(valid) == "SYNTHETIC1"); checks += 1
[files.call([]), files.call(%w[certs/distribution/SYNTHETIC1.cer]), valid.merge("truncated" => true),
 files.call(%w[certs/distribution/A.cer certs/distribution/A.p12 certs/distribution/B.cer certs/distribution/B.p12])].each do |tree|
 reject.call { InsulinOCRSetupPolicy.existing_certificate_id(tree) }; checks += 1
end
ids = %w[test.synthetic.app test.synthetic.app.share]
mapping = {ids[0] => "Existing App Profile 2", ids[1] => "Existing Share Profile 3", "other.app" => "Other"}
assert.call(InsulinOCRSetupPolicy.profile_mapping(ids, mapping) == mapping.slice(*ids)); checks += 1
[nil, {}, {ids[0] => "profile"}, mapping.merge(ids[1] => ""), mapping.merge(ids[1] => "bad\nprofile")].each do |invalid|
 reject.call { InsulinOCRSetupPolicy.profile_mapping(ids, invalid) }; checks += 1
end
env = {"INSULINOCR_DELIVERY_MODE" => "profiles_apply", "GITHUB_REF" => "refs/heads/main",
 "GITHUB_EVENT_NAME" => "workflow_dispatch", "GITHUB_WORKFLOW_REF" => "synthetic/app/.github/workflows/create_profiles.yml@refs/heads/main"}
event = {"inputs" => {"mode" => "prepare_profiles"}}
assert.call(InsulinOCRSetupPolicy.profile_creation_authorized?(env, event)); checks += 1
[env.merge("GITHUB_REF" => "refs/heads/other"), env.merge("GITHUB_EVENT_NAME" => "push"),
 env.merge("GITHUB_WORKFLOW_REF" => "synthetic/app/.github/workflows/testflight.yml@refs/heads/main"),
 env.merge("INSULINOCR_DELIVERY_MODE" => "preflight")].each do |invalid|
 assert.call(!InsulinOCRSetupPolicy.profile_creation_authorized?(invalid, event)); checks += 1
end
assert.call(!InsulinOCRSetupPolicy.profile_creation_authorized?(env, {"inputs" => {"mode" => "check"}})); checks += 1
reject.call { InsulinOCRSetupPolicy.lane("nuke_certs") }; checks += 1
fake = Class.new do
 class << self
  attr_accessor :called
  def generate_certificate(*)
   self.called = true
  end
 end
end
fake.singleton_class.prepend(InsulinOCRSetupPolicy::ExistingCertificateOnly)
reject.call { fake.generate_certificate(:synthetic, certificate_id: "synthetic") }
assert.call(!fake.called); checks += 1
require "match"
Match::Generator.singleton_class.prepend(InsulinOCRSetupPolicy::ExistingCertificateOnly)
reject.call { Match::Generator.generate_certificate(nil, nil, nil) }; checks += 1
puts "Setup policy: #{checks} synthetic authorization, profile selection and certificate-creation checks passed."
