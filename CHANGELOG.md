# Changelog

Release notes describe user-visible changes since the previous version and must always be written in English.
Before publishing a release, add a section with its exact version number.

## [Unreleased]

### Plugins

- Show and enable Cylon only when the engine profile email belongs to `hextra.it`. Other profiles cannot enable it or access its APIs, even when it is installed. Changing the profile email applies the restriction immediately.

## [0.6.1]

### Fixes

- Restore the ClickUp list ID field in both the new project sheet and the project editor, visible only while Cylon is enabled. The project's Save button also saves this value, preserving existing list IDs.
- Keep the working indicator's elapsed time when switching away from a chat and returning while the same turn is running.
- Keep the changelog and generated GitHub and Sparkle release notes in English.

## [0.6.0]

### Projects

- Projects can contain any number of repositories, each with a custom label.
- New projects start in the current chat's folder with the Default label.
- Renaming or reordering repositories preserves bot and channel assignments and project scripts.
- Configure the ClickUp list in the Cylon plugin settings, visible only while the plugin is enabled. Existing settings are preserved.

### Plugins

- Cylon is distributed as a private plugin and is automatically included in builds when the private plugin repository is available.
- App and engine builds can exclude private plugins with `--no-private-plugins`.

### Updates

- Updates download from the public repository without a GitHub token in the app.
- The update window and GitHub release show the same notes, with a comparison against the previous version.

## [0.5.3]

### Projects

- Projects can contain any number of repositories, each with a custom label.
- New projects start in the current chat's folder with the Default label.
- Bots and channels continue to choose the repository they work in. Renaming a label preserves assignments and scripts.
- Configure the ClickUp list in the Cylon plugin settings, visible only while the plugin is enabled. Existing settings are preserved.

### Updates

- Updates download from the public repository without a GitHub token in the app.
- The update window and GitHub release show the same changelog, with changes since the previous version.
