# Security policy

## Supported versions

Use the latest published release. Known limitations and support scope are stated
in [GitHub Releases](https://github.com/aihohu/MomentAI/releases). Development builds
and earlier private application identities are outside the supported release scope.
If there are no published releases, report against the current source commit.

## Report a vulnerability privately

Open [MomentAI security advisories](https://github.com/aihohu/MomentAI/security/advisories)
and choose **Report a vulnerability** when private reporting is enabled. Send the
source commit or app version, a minimal synthetic reproduction, expected behavior,
and likely impact. Do not attach personal recordings, transcripts, credentials,
or signing material. Do not access another person's data to demonstrate a problem.

If the private-report button is unavailable, open a
[contact request](https://github.com/aihohu/MomentAI/issues/new?template=feature_request.yml)
containing only “Please provide a private security contact.” Wait for a private
channel before sharing vulnerability details. Do not include exploit information
or personal data in the public request. Maintainers coordinate disclosure with the
reporter; no fixed response-time guarantee is made.

Review focuses on recording persistence, import validation, unsafe paths, resource
exhaustion, optional AI transmission, secure credentials, and build credentials.
Automated scanning does not replace review or prove the absence of vulnerabilities.
