# Epitome

**Instant file-name search for macOS.** Epitome indexes the name of every file and folder on your Mac, keeps that index current as files change, and filters about a million items as you type.

It is a native, clean-room implementation of the feature set of [Everything](https://www.voidtools.com/) for Windows. The search syntax, filters, bookmarks, file lists, command line and servers are rebuilt for macOS in Swift and AppKit.

> Epitome is an independent project. It is not affiliated with or endorsed by voidtools, and "Everything" is a trademark of its owner.

## Features

- **Live index of every volume.** The first scan reads everything once. After that, Epitome follows FSEvents, and changes made while it wasn't running are caught up at the next start. Restarts load the saved index in about a second.
- **Everything's search syntax:**
  - Operators: AND (space), `|`, `!`, `< >`, quotes.
  - Whole-name wildcards: `*` stays in one folder, `**` crosses folders.
  - Modifiers such as `case:`, `path:`, `ww:`, `wfn:` and `regex:`.
  - About 100 functions: `ext:`, `size:`, `dm:`, `parent:`, `child:`, `dupe:`, `content:`, `width:`, `artist:` and more.
  - Size and date keywords, macros, and search commands (`>rebuild`, `>setting=value`).
- **The search window:**
  - A details view with every column.
  - Thumbnails, a preview pane and Quick Look.
  - Filters, bookmarks, search history and run counts.
  - Multi-file rename.
  - Export to EFU, CSV, TSV, TXT, JSON, M3U or HTML.
- **Settings:** every option, grouped into 18 pages. Any menu shortcut can be changed, and system-wide hotkeys can be set.
- **File lists:** create, edit and search `.efu` lists, for example of a drive that isn't connected.
- **Servers:** an HTTP server for searching from a browser (with a JSON API), and an ETP/FTP server plus a client for searching another Mac.
- **Command line and links:** the `ep` tool for searching from Terminal, app switches, and `epitome:` links.

## Requirements

- macOS 13 Ventura or later, on Apple silicon or Intel.
- To build it: Apple's Command Line Tools (Swift 5.9 or later). Xcode is not needed.

## Install

Build the installer package, then open it:

```sh
git clone https://github.com/CJXanderr/Epitome.git
cd Epitome
bash tools/build.sh pkg
open build/Epitome-*.pkg
```

The package installs Epitome in `/Applications` and the `ep` command in `/usr/local/bin`. To run Epitome straight from the build folder instead, use `bash tools/build.sh run`.

### Permissions

Epitome reads file names, sizes and dates. It reads file contents only when you search for content.

For a complete index, turn on **Full Disk Access**: System Settings → Privacy & Security → Full Disk Access → add Epitome. Without it, two things happen:

- macOS asks separately for each protected place: Desktop, Documents, Downloads, iCloud Drive, external and network drives, and other apps' data.
- Epitome skips folders such as Mail and Messages.

Builds are signed ad hoc, with no Developer ID. macOS therefore treats every new build as a new app, and Full Disk Access has to be turned on again after installing one.

## Searching

| Search | Finds |
| --- | --- |
| `report pdf` | names containing both words, in any order |
| `jpg\|png` | either word |
| `invoice !draft` | names with "invoice" but not "draft" |
| `"meeting notes"` | the exact text, spaces included |
| `ext:heic;jpg;png` | those extensions |
| `size:>1gb` | files over 1 GB |
| `dm:thisweek` | items modified this week |
| `~/Projects/ *.swift` | Swift files anywhere under ~/Projects |
| `folder: empty:` | empty folders |
| `ext:mp4 dupe:` | .mp4 files that share a name with another one |
| `ext:md content:TODO` | Markdown files containing "TODO" |

Help → Search Syntax in the app documents everything, and its examples run when you click them.

## Command line

```sh
ep report pdf                                  # print matching paths
ep -n 20 -sort size-descending ext:mov         # the 20 largest .mov files
ep -size -date-modified -csv dm:today > today.csv
ep -gui -search "invoice" -filter Document     # open a search window
ep -help
```

`ep` talks to the running app, so Epitome must be open. Tools → Install Command Line Tool links it into `/usr/local/bin`, or the package does it for you.

## Development

```sh
bash tools/build.sh build     # compile and assemble build/Epitome.app
bash tools/build.sh run       # build, then (re)launch the app
bash tools/build.sh test      # engine self-tests
bash tools/build.sh pkg       # universal app and build/Epitome-<version>.pkg
bash tools/build.sh clean
```

The engine is portable Swift and builds on Linux too: `swift run epitome-selftest`.

| Path | Contents |
| --- | --- |
| `Sources/EpitomeCore/` | Index, parallel scanner, database, FSEvents updater and journal; query parser, compiler and evaluator; settings, file lists, formatting; IPC, HTTP and ETP servers |
| `Sources/Epitome/` | The AppKit app |
| `Sources/ep/` | The command-line client |
| `Sources/EpitomeSelfTest/` | Engine tests and benchmarks |
| `Resources/` | `Info.plist`, the app icon and the help pages |
| `tools/` | Build script and installer-package resources |

## How it was made

Epitome is a clean-room implementation. A functional specification of Everything's behavior was written from its public user documentation, and the code was written from that specification. No voidtools source code, binaries or other assets were used.

## License

[MIT](LICENSE)
