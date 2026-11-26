# Maintain public documentation

[简体中文](MAINTAINING.zh-CN.md) · [Documentation](README.md)

For contributors editing prose, examples, navigation or build/release instructions.
Use [CONTRIBUTING](../CONTRIBUTING.md) for code and commit policy. Keep documentation
with its code revision; feature changes update the corresponding guide in the same PR.

## Ownership and admission

| Location | Responsibility |
| --- | --- |
| Root README pair | Product introduction, stable entry links, license pointers |
| Root community/security/legal files | Contributor workflow, disclosure and legal policy |
| `docs/` | Reviewed user, build, architecture, test and release task guides |
| `docs/manifest.json` | Explicit first-party prose inclusion list, reader and language pairs |
| `docs/decisions/` when needed | Reviewed long-lived architecture decisions, linked from architecture |
| `.local/plans/`, `.local/notes/`, `.local/prototypes/` | Specs, execution plans, debug notes and experiments |
| `.local/validation/`, `.local/archive/` | Raw evidence/attachments and preserved originals with move records |
| `third_party/` | Original upstream legal material; separate from first-party prose admission |

There is no docs-site build. Do not create empty sections, a parallel handbook, or a
site deployment claim. Keep one body per topic and language; other pages link to it.
Use code/Schema links for changing interface details. A hand-written table is not
a complete generated API reference. Public examples use synthetic inputs and no
credentials, private media or author-specific absolute paths.

Before implementation, write the intended behavior and decisions as a local spec.
Team decisions must also be shared in an Issue/PR or team platform; `.local/` alone
is not collaboration. Promote only reviewed, implementation-backed material into
public guides. Put accepted enduring tradeoffs in ADRs; proposals remain clearly
labeled and must not appear as delivered features. Keep temporary execution lists local.

## Update and verify

1. Read the relevant implementation, tests, build settings and workflow. Define the
   reader, prerequisites, support scope, task steps, expected outcome, recovery and
   limits. Do not publish roadmap capabilities as working features.
2. Preserve originals under `.local/archive/` before moving existing content and
   record old/new paths. Moving or ignoring a file does not remove Git history.
3. Edit both language counterparts, reciprocal switches and the task index. Root
   English policy/legal files remain authoritative; do not fabricate translations
   by changing dates. Preserve effective URLs with a linking page/anchor if needed.
4. Add each first-party prose file to the manifest with its audience and translation
   (or explicit single-language policy). Review the diff before accepting inclusion.
   Do not add every local file to make a check pass.
5. With the [shared dependencies](BUILDING.md) installed, run:

```sh
npm run lint:docs
python scripts/check_documentation.py
python scripts/check_repository.py
python -m unittest discover -s scripts/tests
python scripts/dev.py check
```

Also follow changed setup/tutorial instructions in an isolated clean environment,
then run affected [behavior and platform tests](TESTING.md). Record exact results,
skips and cache use under `.local/validation/`; attach only a sanitized summary to
the PR. Examples must include target files, imports, dependency wiring, configuration,
permissions, migrations and run/verification steps when applicable. Prefer one checked
example source referenced by translations. No test replaces content review.

## Public scope and packaging

Navigation, Git ignoring, source archives and app packaging are independent:

- The manifest and Markdown checks cover public navigation, links, anchors and
  paired pages. Unlisted first-party prose and links to local/private files fail.
- `.gitignore` keeps `.local/` out of ordinary staging; repository checks also reject
  force-added private material. Review the candidate diff and history before release.
- `.gitattributes` excludes process directories from `git archive`; the archive checker
  can verify actual source TARs and ZIP/APK/IPA entries without extracting them.
- `pubspec.yaml` explicitly includes legal notices and the bundled model assets;
  public prose and process evidence are not app assets. Native packaging and actual
  release files still need [release inspection](RELEASING.md).

The checks do not validate external URLs, translation semantics, all Markdown
extensions, screenshots, runtime permissions or independent approval. Local links
use inline Markdown or reference definitions; use explicit HTML `id` anchors only
when needed. If a docs site is later added, review metadata/canonical, sitemap,
language correspondence, search, keyboard/mobile/theme behavior and reduced motion
before publishing it; none is implied by the repository checks.

## Signing credentials

Signing private keys, keystores, passwords, credential configuration, signing backups
and filing records must remain outside the public repository and release assets.
Public certificates embedded in signed applications are part of the distribution format.

Repository and archive checks reject common signing inputs; they do not replace a
credential review. CI does not upload raw test-result bundles or native audit reports
as artifacts. Public CI logs must not contain credentials or private application data.
