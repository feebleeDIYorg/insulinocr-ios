require "pilot"
require "pilot/build_manager"
require "ostruct"
require_relative "../fastlane/lib/insulinocr_setup_policy"

# Exercise the pinned Pilot implementation with local models, never Apple APIs.
class SyntheticDistributionBuild
  attr_reader :review_requests, :assigned_groups
  def initialize
    @review_requests = 0
    @assigned_groups = []
  end
  def app_version; "0.1.0"; end
  def version; "1"; end
  def uses_non_exempt_encryption; false; end
  def ready_for_beta_submission?; true; end
  def post_beta_app_review_submission
    @review_requests += 1
    raise "Synthetic review request intercepted"
  end
  def app
    group = Object.new
    def group.matches_identifiers?(identifiers); identifiers == ["InsulinOCR Internal"]; end
    OpenStruct.new(get_beta_groups: [group])
  end
  def add_beta_groups(beta_groups:); @assigned_groups = beta_groups; end
  def get_beta_build_localizations; []; end
end

checks = 0
manager = Pilot::BuildManager.new
defaults = FastlaneCore::Configuration.create(Pilot::Options.available_options,
  groups: ["InsulinOCR Internal"], distribute_external: false)
raise "Pinned default changed" unless defaults[:submit_beta_review] == true
build = SyntheticDistributionBuild.new
begin
  manager.send(:distribute_build, build, defaults)
  raise "Expected the old internal-group review behavior"
rescue RuntimeError => error
  raise unless error.message == "Synthetic review request intercepted" && build.review_requests == 1
end
checks += 1

options = FastlaneCore::Configuration.create(Pilot::Options.available_options,
  InsulinOCRSetupPolicy.internal_distribution_options("qa_distribute", "Synthetic QA notes"))
build = SyntheticDistributionBuild.new
manager.send(:distribute_build, build, options)
raise "External review or missing internal assignment" unless build.review_requests.zero? && build.assigned_groups.length == 1
raise "External notifications enabled" unless options[:notify_external_testers] == false
checks += 1

writes = []
manager.define_singleton_method(:update_localized_build_review_for_lang) do |_build, localization, locale, info|
  writes << {localization: localization, locale: locale, info: info}
end
manager.send(:update_localized_build_review, build, {}, default_info: {whats_new: "Synthetic old notes"})
raise "Pinned first-build behavior changed" unless writes.empty?
manager.send(:update_localized_build_review, build, options[:localized_build_info])
raise "First build notes not created" unless writes.length == 1 && writes[0][:localization].nil? && writes[0][:locale] == :"de-DE"
raise "QA limitation missing" unless writes[0][:info][:whats_new].start_with?(InsulinOCRSetupPolicy::QA_NOTICE)
checks += 1
puts "Internal distribution: #{checks} pinned-Pilot regressions passed (synthetic; no network)."
