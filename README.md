# Smol Todo

A small macOS todo app with a shared command line interface.

## Build

```sh
swift build
```

To create the macOS app bundle:

```sh
./Scripts/package-app.sh <build-id>
```

The app bundle is written to `dist/SmolTodo.app`.

## Run the GUI

```sh
swift run SmolTodo
```

The app stores data at:

```text
~/Library/Application Support/SmolTodo/todos.json
```

Set `SMOL_TODO_STORE=/path/to/todos.json` to use a different store, which is useful for tests or local experiments.

## CLI

```sh
todo item create [-c|--collection <collection>] <title...>
todo item get [-s|--status <status>] [--priority <priority>] [-c|--collection <collection> | <id...>]
todo item update <id> [-c|--collection <collection>] [-s|--status <status>] [--priority <priority>] [<title...>]
todo item assign <id> (--assignee <assignee> ... | --unassign)
todo item delete <-c|--collection <collection> | <id...>>
todo collection list
todo collection create <name>
todo collection rename <old-name> <new-name>
todo collection color <name> <gray|red|orange|yellow|green|blue|purple>
todo collection delete <name>
todo collection clear <name> [--completed]
```

`todo item update --status` requires one status: `ready`, `draft`, `in-progress`, `completed`, `on-hold`, or `aborted`.
`todo item update --priority` requires one priority: `normal` or `prioritized`.
`todo item update` changes an existing item in place without changing its id.
`todo item assign` replaces the assignees for an item, and `--unassign` clears them.

Examples:

```sh
todo item create --collection Inbox "Buy milk"
todo item get
todo item get -s ready -c Inbox
todo item get --priority prioritized -c Inbox
todo item update 1a2b3c4d --collection Errands -s ready --priority prioritized "Buy oat milk"
todo item assign 1a2b3c4d --assignee Kai --assignee Mina
todo item assign 1a2b3c4d --unassign
todo item update 1a2b3c4d --priority prioritized
todo item update 1a2b3c4d --priority normal
todo item update 1a2b3c4d --status completed
todo item update 1a2b3c4d --status draft
todo item update 1a2b3c4d --status in-progress
todo item update 1a2b3c4d --status on-hold
todo item update 1a2b3c4d --status aborted
todo item delete 1a2b3c4d
todo item delete --collection Inbox
todo collection list
todo collection create Errands
todo collection rename Errands Personal
todo collection color Personal blue
todo collection clear Personal --completed
todo collection delete Personal
```

The GUI settings window can install a `todo` symlink into `~/.local/bin/todo`. For a packaged `.app`, place the CLI binary at:

```text
SmolTodo.app/Contents/Library/Helpers/todo
```
