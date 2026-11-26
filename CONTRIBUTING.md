# Contributing to MomentAI

Discuss substantial changes before implementation. Fixes, reproducible reports,
translations, and focused tests are welcome.
Complete the [README setup](README.md#build-from-source) before running checks.
Use synthetic fixtures when changing shared data or native recording behavior.

## Workflow

1. Create a focused branch from `main`.
2. Make one coherent change. Separate mechanical formatting from behavior changes.
3. Run the shared checks and affected platform checks; add a regression for a bug.
4. Describe the trigger, resulting behavior, validation, and limitations in the PR.
5. Resolve review feedback and required checks before merge.

Contributors are responsible for code they submit, including AI-assisted changes.
Do not weaken assertions or silently skip checks to obtain a green result.

## Code standards

- Use English identifiers, comments, test names, and internal diagnostics.
- Explain non-obvious constraints and decisions; do not paraphrase every statement.
- Keep functions and modules cohesive. Extract responsibilities when it improves
  comprehension, not to meet an arbitrary line-count target.
- Await asynchronous work or explicitly mark intentional fire-and-forget calls.
- Preserve committed audio and source anchors; display offsets are not timestamps.
- Handle errors at a meaningful boundary. User-facing failures must be localized.
- Add both English and Chinese resources for user-facing text.
- Keep generated and third-party files out of manual formatting changes.
- Add dependencies only with a reason, pinned resolution, provenance, and license review.

Use `python3 scripts/dev.py format` and `python3 scripts/dev.py check`.
Markdown is checked with pinned [markdownlint-cli2](https://github.com/DavidAnson/markdownlint-cli2);
`format` applies its supported fixes. Native formatting uses `--platform android` or `--platform ios` after platform
preparation in README.
Local and CI rules must match. Narrow exceptions need a reason beside the exception.

## Commits

Use one English imperative line, at most 100 characters:

```text
feat(recording): add resilient pause and resume
fix(archive): reject invalid audio boundaries
test(models): verify interrupted downloads
```

Allowed types: `feat`, `fix`, `refactor`, `test`, `docs`, `build`, `ci`, `chore`,
`perf`, `style`, and `revert`. Scope must name a stable area. No body, copyright
statements, attribution trailers, or automated co-author lines. Required license
and attribution text belongs in the relevant source or notice files.

Enable the versioned local commit hook once per checkout:

```sh
git config core.hooksPath .githooks
```

PR titles follow the same convention. CI checks PR titles, human-authored PR
commits, and all new commits pushed to `main`. Dependabot PRs retain their generated
commit metadata during review; squash them into the approved PR title with an
empty commit body when merging. The final commit follows the same policy.

## Tests and fixtures

Tests must assert observable behavior, be independent of execution order, and fail
for the regression they cover. Avoid arbitrary sleeps, network access, and large
model dependencies in default tests. Public fixtures need provenance and a
reproduction method. Chinese test content is appropriate for language behavior.

Never submit private audio, photos, transcripts, databases, keys, signing files,
absolute workstation paths, or historical diagnostic dumps. Use synthetic data.
Data-contract changes require coordinated iOS/Android review and compatibility tests.

## Documentation and review

Update the affected [task guides](docs/README.md) in both languages with behavior or
setup changes. Follow the [documentation maintenance policy](docs/MAINTAINING.md)
for public admission, review, publication scope and checks. Process plans and raw
acceptance evidence belong under ignored `.local/`; share collaborative design in
an Issue or PR. Preserve original material and record moves before reorganizing it.
Original third-party legal texts remain in `third_party/`. Review both staged files
and reachable Git history before the first publication; ignoring a file does not
remove its history.

Before release, maintainers configure protected branches, required CI checks, and
review requirements. Where a sole maintainer cannot obtain independent review,
record that limitation; do not manufacture an approval.

Contributions are offered under the repository license. Preserve third-party
notices and follow the [Code of Conduct](CODE_OF_CONDUCT.md).

Model changes require exact weight/conversion provenance and synchronized offline
notices. A native package’s top-level license does not replace its linked-library
review; see [Third-party notices](THIRD_PARTY_NOTICES.md) and the pinned
[native input lock](native/runtime-lock.json).

## Test commands

Use the [testing guide](docs/TESTING.md) for shared/native commands, fixture provenance,
clean setup and device acceptance boundaries.
