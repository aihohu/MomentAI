# Prepare a release

[简体中文](RELEASING.zh-CN.md) · [Documentation](README.md)

For maintainers with signing access after [build setup](BUILDING.md). The
[Quality workflow](../.github/workflows/quality.yml) validates source, builds an Android Debug APK and an
unsigned iOS app, and runs tests. It does not publish production releases or upload
test-result artifacts. Job logs follow repository access and retention settings.
Signing and distribution are manual. A successful CI run alone is not release approval.

## Candidate and compatibility

1. Update the app version/build number in [pubspec.yaml](../pubspec.yaml) and the
   documentation index, then commit the reviewed changes. Record the final release
   candidate commit and verify its CI results. Do not confuse
   the Node tooling package with the app version. Never reuse an installed build
   number without checking the target distribution channel.
2. Review data compatibility in both native stores and archive importers. Test
   opening a synthetic recording from the previous supported release and round-trip
   exchange. Keep a verified export before upgrading. Downgrades are not a recovery
   strategy when an older binary cannot understand newer data; do not uninstall a
   user's app to bypass signing or migration errors.
3. Run [shared and native checks](TESTING.md), then separately accept signed products
   on the stated devices. Cover permission denial/retry, pause/resume, interruption,
   background capture, anchored playback, models and cross-platform transfer.
   Record skipped checks, device/OS/tool versions and known limitations explicitly.

## Package and inspect

Follow the signing commands in [Android](BUILDING.md#android) or
[iOS](BUILDING.md#ios). Keep signing credentials outside Git and release assets.
Before Android builds, confirm `MOMENTAI_SIGNING_PROPERTIES` selects the current
release configuration. Compare the APK certificate SHA-256 with the release
certificate recorded by the maintainer; a mismatch blocks publication.

For iOS, select the provisioned Runner scheme and **Product → Archive** in Xcode,
then use Organizer's **Distribute App** to submit to App Store Connect.
Use App Store for production distribution and TestFlight for beta testing.
An unsigned `Runner.app`
is only build evidence. Confirm application ID, version, signing identity and bundled
models on the output. Keep `ENABLE_INTERNAL_TOOLS` and `MOMENTAI_INTERNAL_TESTS` out
of product builds.

```sh
mkdir -p .local/validation/release
"${ANDROID_HOME:?Set ANDROID_HOME}/build-tools/36.0.0/apksigner" verify --verbose --print-certs \
  build/app/outputs/flutter-apk/app-release.apk \
  > .local/validation/release/android-signature.txt
git archive --format=tar HEAD -o .local/validation/release/source.tar
python scripts/check_documentation.py --archive .local/validation/release/source.tar
python scripts/check_documentation.py --archive build/app/outputs/flutter-apk/app-release.apk
```

The source archive represents committed `HEAD`, not uncommitted work. Run this after
the candidate is committed. Review the signature report locally; do not publish
signing configuration or diagnostic reports. Inspect native linkage with `audit_native_runtime.py` as in the build guide, Android
alignment with `python scripts/check_android_native_alignment.py build/app/outputs/flutter-apk/app-release.apk`,
and license coverage against [third-party notices](../THIRD_PARTY_NOTICES.md).
Archive path screening does not replace these checks or a review for personal data.

## Publish selected material

Review the [documentation manifest](manifest.json), candidate diff and reachable
history. Prepare release notes with the actual application version, source revision,
supported platforms, changes, migration/recovery instructions and known limitations.
GitHub Releases distributes the production-signed Android Release APK, its SHA-256
checksum, and reviewed release notes. The release tag must reference the accepted
candidate commit. Include the App Store link for iOS; do not attach an IPA.
Generate checksums from the final artifacts and retain the validation records locally.
Do not upload `.local/`, raw acceptance logs, source caches or signing credentials.
If required checks fail, keep the release unpublished. Corrections to distributed
artifacts require a new version/build and updated release notes.
The public source archive retains curated docs and legal notices. No automatic
release job or fixed release cadence is configured in this repository.

Use the [security policy](../SECURITY.md) for vulnerability handling. Retain existing
[license](../LICENSE), [notice](../NOTICE) and artwork declarations. Where independent
review was unavailable, state that fact; do not represent local validation as approval.
