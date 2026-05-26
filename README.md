# Smol Todo

A small macOS todo app with a shared command line interface.

## Build

```sh
swift build
```

To create the macOS app bundle:

```sh
./Scripts/package-app.sh
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
todo add [--collection <collection>] <title...>
todo get [done|undone] [--collection <collection> | <id...>]
todo set <done|undone|locked|unlocked>... <--collection <collection> | <id...>>
todo delete <--collection <collection> | <id...>>
```

`todo set` requires at least one state: `done`, `undone`, `locked`, or `unlocked`. State arguments can be provided in any order.

Examples:

```sh
todo add --collection Inbox "Buy milk"
todo get
todo get undone --collection Inbox
todo set done 1a2b3c4d
todo set undone --collection Inbox
todo set locked 1a2b3c4d
todo set done locked 1a2b3c4d
todo set locked done 1a2b3c4d
todo set unlocked 1a2b3c4d
todo delete 1a2b3c4d
todo delete --collection Inbox
```

The GUI settings window can install a `todo` symlink into `~/.local/bin/todo`. For a packaged `.app`, place the CLI binary at:

```text
SmolTodo.app/Contents/Library/Helpers/todo
```
