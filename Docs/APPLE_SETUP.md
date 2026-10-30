# Private deployment configuration

Keep account-specific setup records outside the public repository. Configure
Apple team, App Store app, capabilities, signing profiles and private Match
storage for your account. No certificate, profile, private key, password, device
identifier or private QA dataset belongs in this repository.

Supply TEAMID and the private INSULINOCR_BUILD_CONFIG outside Git. See
[the configuration contract](BUILD_CONFIGURATION.md) for all required fields.
The private signing repository remains private, including encrypted key files.
Reuse existing authorized credentials where available; verify secret visibility
and encrypted-store compatibility before any release. A repository becoming
public can make organization secrets eligible for its workflows without making
their values public. Configure deployment restrictions before running delivery.
