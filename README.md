# GitHubLegacyFix

A CydiaSubstrate tweak that makes old versions of the GitHub iOS app work again by patching deprecated GraphQL fields that no longer exist in GitHub's schema.

## Background

Old versions of the GitHub app embed Apollo-generated GraphQL queries that reference fields GitHub has since removed:

| Removed field / type | Affected app versions | Replacement |
|---|---|---|
| `projectCards` on `Issue`/`PullRequest` | 1.148.0+ | `projectItems` (Projects V2) |
| `renderMobileTasklistBlocks: true` argument on `bodyHTML()` | 1.148.0+ | Argument dropped |
| `projectNextItems` on `Issue`/`PullRequest` | ~1.43.0 - ~1.78.0 | `projectItems` (Projects V2) |
| `projectsNext` on `User`/`Organization`/`Repository` | ~1.43.0 - ~1.78.0 | `projectsV2` (Projects V2) |
| `ProjectNext*` types | ~1.43.0 - ~1.78.0 | `ProjectV2*` types |

When the server receives any of these, it returns a GraphQL `undefinedField` error. Apollo's error handling in these old app versions results in a "Something went wrong." screen on issue, pull request, repository, and profile pages.

**Mixed-error responses:** Queries like `UserProfileQuery` fetch both a `user` and an `organization` root field in a single request. When viewing an org profile, `user` correctly returns `null` alongside a `NOT_FOUND` error, while `organization` returns full data alongside a `projectsNext undefinedField` error. The tweak handles this by stripping only `undefinedField` errors for known legacy fields and preserving all other errors, so Apollo's partial-data handling works correctly.

## What it does

**Outbound request patching** (hooks `NSURLSession`):
- Strips the deprecated field arguments and fragment spreads from the query string before it reaches the server.
- Removes the now-orphaned fragment definitions (which GitHub's schema validator would otherwise reject).

**Inbound response patching** (hooks `Apollo.URLSessionClient`):
- Strips non-fatal schema-validation errors from the response when `data` is still present, so Apollo doesn't treat the response as a failure.
- Re-injects empty stub objects for the removed fields (`projectCards`, `projectNextItems`, `projectsNext`) so Apollo's compiled Swift decoder — which was generated expecting those fields — doesn't throw a missing-key error.

## Supported versions

| GitHub iOS | iOS |
|---|---|
| 1.43.0 | 13+ |
| 1.78.0 | 14+ |
| 1.148.0 | 15+ |

## Requirements

- Jailbroken device
- iOS 13.0 – 15.8
