# Pond

A small macOS task app with a shared command line interface.

## Build

```sh
swift build
```

To create the macOS app bundle:

```sh
./Scripts/package-app.sh
```

The app bundle is written to `dist/Pond.app`.

To create a bundle with explicit release metadata:

```sh
./Scripts/package-app.sh --version 0.1.0 --build 0.1.0.123
```

## Run the GUI

```sh
swift run Pond
```

The app stores data at:

```text
~/Library/Application Support/Pond/todos.json
```

Set `POND_STORE=/path/to/todos.json` to use a different store, which is useful for tests or local experiments.

## Release

Releases are distributed from GitHub as a notarized ZIP. The release script requires a local Developer ID Application certificate, a stored notarytool Keychain profile, and an authenticated `gh` CLI session.

One-time notarization credential setup:

```sh
xcrun notarytool store-credentials PondNotary --apple-id <apple-id> --team-id <team-id>
```

Create and push a `vX.Y.Z` tag on the exact commit to release, then run:

```sh
export DEVELOPER_ID_APPLICATION="Developer ID Application: <name> (<team-id>)"
./Scripts/release.sh
```

`Scripts/release.sh` derives:

```text
CFBundleShortVersionString = X.Y.Z
CFBundleVersion = X.Y.Z.W
```

`W` is `git rev-list --count HEAD`. The script signs `dist/Pond.app`, submits it to Apple notarization, staples the ticket, validates Gatekeeper assessment, creates `Pond-vX.Y.Z-macOS.zip`, writes a SHA-256 checksum, and creates the GitHub Release with both files attached.

## CLI

```sh
taskpond item create [-c|--collection <collection>] <title...>
taskpond item get [-s|--status <status>] [--priority <priority>] [-c|--collection <collection> | <id...>]
taskpond item update <id> [-c|--collection <collection>] [-s|--status <status>] [--priority <priority>] [<title...>]
taskpond item assign <id> (--assignee <assignee> ... | --unassign)
taskpond item delete <-c|--collection <collection> | <id...>>
taskpond collection list
taskpond collection create <name>
taskpond collection rename <old-name> <new-name>
taskpond collection color <name> <gray|red|orange|yellow|green|blue|purple>
taskpond collection delete <name>
taskpond collection clear <name> [--completed]
```

`taskpond item update --status` requires one status: `ready`, `draft`, `in-progress`, `completed`, `on-hold`, or `aborted`.
`taskpond item update --priority` requires one priority: `normal` or `prioritized`.
`taskpond item update` changes an existing item in place without changing its id.
`taskpond item assign` replaces the assignees for an item, and `--unassign` clears them.

Examples:

```sh
taskpond item create --collection Inbox "Buy milk"
taskpond item get
taskpond item get -s ready -c Inbox
taskpond item get --priority prioritized -c Inbox
taskpond item update 1a2b3c4d --collection Errands -s ready --priority prioritized "Buy oat milk"
taskpond item assign 1a2b3c4d --assignee Kai --assignee Mina
taskpond item assign 1a2b3c4d --unassign
taskpond item update 1a2b3c4d --priority prioritized
taskpond item update 1a2b3c4d --priority normal
taskpond item update 1a2b3c4d --status completed
taskpond item update 1a2b3c4d --status draft
taskpond item update 1a2b3c4d --status in-progress
taskpond item update 1a2b3c4d --status on-hold
taskpond item update 1a2b3c4d --status aborted
taskpond item delete 1a2b3c4d
taskpond item delete --collection Inbox
taskpond collection list
taskpond collection create Errands
taskpond collection rename Errands Personal
taskpond collection color Personal blue
taskpond collection clear Personal --completed
taskpond collection delete Personal
```

The GUI settings window can install a `taskpond` symlink into `~/.local/bin/taskpond`. For a packaged `.app`, place the CLI binary at:

```text
Pond.app/Contents/Library/Helpers/taskpond
```
