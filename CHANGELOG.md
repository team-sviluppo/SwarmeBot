# Changelog

Release notes describe user-visible changes since the previous version and must always be written in English.
Before publishing a release, add a section with its exact version number.

## [0.6.6]

### Automations

- Keep an automation's results in one conversation with the new **Output in the same chat** option. Each run continues in the latest `[AUTOMAZIONE]` chat for that automation and makes it the bot's current chat; a new one is opened only when none exists.
- Automations without the option, and webhook runs, still open a new chat for every run. The setting moves with a bot transferred to another engine.

## [0.6.5]

### Remote servers

- Check and update installed Codex, Claude Code and omp harnesses automatically when SwarmeBot starts. Wait while bots are working, retry when they finish, and show each server's result in Remote Servers settings.
- Check for updates manually from the server's Actions menu. Keep logins and configuration, preserve newer versions, and verify official Codex and omp downloads before installing them.

### Fixes

- Install the complete Codex runtime on remote Linux and macOS servers so bots can execute commands. Repair incomplete installations even when the CLI still reports its version, and install Linux sandbox prerequisites during server setup.
- Show Codex runtime and configuration warnings in the chat instead of hiding the reason tools are unavailable.

## [0.6.4]

### Skills

- Control all installed Cylon skills from a single **Cylon** switch in the bot's details. One save sets the default for every member while preserving other skills and existing per-chat choices.
- See how many skills are enabled when the group is partially active, and enable the full group or disable all members together.
- Keep disabled Cylon skills off even when a GitHub source assigns them automatically. Individual skill files and slash commands remain available as usual.

## [0.6.3]

### Fixes

- Show a single, localized warning when shared folders are unavailable, with directions to the Sharing settings. Dismissed warnings stay quiet across automatic reconnections until the folders recover; manual refresh still reports current problems.
- Preserve errors from other actions during automatic shared repository synchronization and clear the folder warning after recovery.
- Recognize GitHub skill repositories such as Cylon whose skill folders are directly at the repository root when the default `skills` entry is absent. Keep validation of custom paths, existing folders and symbolic links, and preserve installed skills when an update is invalid.

## [0.6.2]

### Plugins

- Show and enable Cylon only when the engine profile email belongs to the exact `hextra.it` domain. Missing emails, other domains and subdomains keep it hidden and disabled, even when installed.
- Apply profile email changes immediately across connected clients, blocking Cylon APIs and turn hooks for ineligible profiles while preserving plugin settings and the manual on/off choice.

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
