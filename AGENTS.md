# ResolveScopes iPad

This is the canonical iPad application repository. Its GitHub visibility must remain **public**.

The user explicitly requests that future changes be versioned here and uploaded to this repository's GitHub remote. After implementing an authorized change:

1. Inspect Git status and preserve unrelated work.
2. Update the affected app version and release notes when releasing an application change; documentation-only maintenance does not require an app version bump.
3. Run checks appropriate to the change, commit the completed work, and push to the existing remote. This push authorization persists unless the user explicitly asks for local-only work or no push.
4. Verify the remote commit and report the pushed version/commit and any concrete verification limits.

Do not force-push, rewrite history, change visibility or overwrite others' work without explicit authorization. Use `codex/` as the prefix when creating a task branch.

The shared scope engine and rendering helpers are copied into the separate macOS repository. Synchronize required shared changes deliberately, verify each affected platform, and version/commit/push each repository independently. Neither application should require access to the other repository to build.

Do not commit credentials, signing certificates, provisioning profiles, personal development Team identifiers, live footage, local diagnostics or build outputs. Preserve third-party notices. Public visibility does not grant an open-source license; do not add or change licensing terms unless requested.
