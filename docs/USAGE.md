# Use and protect recordings

[简体中文](USAGE.zh-CN.md) · [Documentation](README.md)

Check [GitHub Releases](https://github.com/aihohu/MomentAI/releases) for published
packages and installation instructions. If no package is available for your
platform, use the [build guide](BUILDING.md). Git contains no model weights,
compiled apps, or signing credentials.

1. Tap **Start recording** and allow microphone access. The built-in lightweight
   Mandarin model works offline; choose **Later** to postpone optional downloads.
2. Add photos, notes, or highlights. Use **Pause recording** and **Resume recording**
   when needed. Pauses do not add silence to saved audio.
3. Tap **Finish and save**, wait for completion, then replay the recording.
   Open saved items from **Recordings**; timeline items link to audio positions.
4. To transfer a recording, choose **Recording actions → Share and export →
   Create export**, wait for verification, and share the `.momentai` file.
5. On the receiving device, choose **Recordings → Import recording**, select
   the original file, review the preview, and choose **Import and open**.

Save through the system share sheet: **Save to Files** on iPhone, or an available
file provider on Android. If Android offers no local Downloads destination, use
another local provider or transfer through a trusted share destination. Verify
imported audio, photos, and text before deleting the source. Keep archives unchanged;
recompressed, encrypted, split archives and files over 2 GiB are unsupported.

## Features and privacy

- Audio recording, pause/resume, interruption recovery, and anchored playback.
- On-device transcription, optional refinement and speaker labeling, recording search.
- Photos, notes, and highlights at original audio positions; text, Markdown, WAV,
  and complete `.momentai` recording export/import.
- English/Chinese interfaces and optional AI summaries/conversations.

Recordings and local speech analysis remain in the app's private container.
Manage optional models in **Settings → Transcription model**; downloads contact
model hosts. Remote AI sends text/context to your selected provider after consent
and does not attach audio or photos. Keys use platform secure storage.
`.momentai` excludes keys, model files, AI conversations, and app settings.
File providers may use their own cloud storage. Export important recordings before
uninstalling or clearing data; do not rely on system backup for all app content.
Android recordings use no-backup storage; iOS recording storage is in Application
Support, while Documents exposes exchange files. Backup behavior differs by platform.

Build targets are Android ARM64 (API 24+) and iOS (15+); these minimums do not imply
verification on every device. Release notes state actual support and limitations.
Manual transcript correction, cloud synchronization, OCR, cross-recording speaker
identity, and `.tracenote` import are outside the current feature set.

## Permissions and a first recording

Use a short, non-sensitive sentence on a test device. Microphone permission is
required to record; camera permission is needed only for photos. If denied, open
system settings for MomentAI, enable the needed permission, and retry. Android uses
a microphone foreground service and requests notification permission on supported
OS versions. Notification permission does not replace microphone permission.

After saving, confirm the sentence is audible, the timeline opens its audio position,
and any photo/note is present. Transcription can be imperfect; retain original audio.
If recording is interrupted, inspect the displayed state and recovery entry before
starting another recording. Never assume background capture continued through a call
or an OS termination. If a save fails for lack of space, free unrelated storage and
retry/reopen recovery; do not clear the app's data to recover a recording.

## Optional AI

Open **Settings → AI services**, add a service, choose OpenAI Compatible or Anthropic
Messages, and enter your provider's HTTPS API base URL and key. Add the provider's
exact model ID and save. Open a saved recording's AI summary or conversation, select
the configured model, review the text/context and consent prompt, then submit.
A saved configuration alone does not verify provider compatibility or available credit.

The base URL cannot contain embedded credentials, a query, or a fragment. For an
authentication/model error, check the key, endpoint and model ID with that provider;
do not paste the key into an issue. Cancellation stops local generation handling but
the provider may still charge. AI output needs human review and is not original audio.

## Confirm a transfer

Use the export/import sequence above with a short synthetic recording. Compare
playback duration, a known audio position, text and photos on the receiving device.
For rejected archives, transfer the original `.momentai` again without repackaging;
keep the source until verified. Import is a copy, not synchronization. If you need
to recover from uninstall/data removal without an export, this app provides no cloud
restore service. Report a reproducible problem using the [contribution guide](../CONTRIBUTING.md).
