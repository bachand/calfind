# Calfind

Calfind is a macOS command-line tool for searching CalDAV calendars by event title, location, or notes.

## Quick start

The fastest way to get started is with iCloud Calendar, which can discover and save a calendar in one step.

```sh
swift run calfind auth icloud
```

The command asks for your Apple Account email and app-specific password once, discovers your calendars, lets you choose one, and saves it.

Search a saved calendar:

```sh
swift run calfind "Alice Chen" 2026-01-01 2026-01-31 --calendar personal
```

Example output:

```text
2026-01-08 12:30  Lunch with Alice Chen
2026-01-21 15:00  Project sync with Alice Chen
```

Each match shows its start time and title. Add `--show-duration` to include the duration before the title (for example, `(1h 30m)` or `(2d)` for an all-day event). Add `--show-location` to print each event's location below its title. If nothing matches, `calfind` prints `No matching events found.`

Dates are interpreted and results are printed in the system time zone by default.

## Other CalDAV providers

For a provider other than iCloud, first discover its calendar collection URLs:

```sh
swift run calfind auth discover --server https:\/\/caldav.example.com
```

Example output:

```text
Work
  https:\/\/caldav.example.com\/calendars\/me\/work\/
Personal
  https:\/\/caldav.example.com\/calendars\/me\/personal\/
```

It prompts for your username and password first.

Choose the collection URL from the results, then save it with a name:

```sh
swift run calfind auth login --calendar work \
  --caldav-url "https:\/\/caldav.example.com\/calendars\/me\/work\/"
```

The login command prompts for any missing values, such as the username and password. Depending on the provider, use its app-specific password or access token. If you already know the collection URL, you can skip discovery and go straight to `auth login`.

Alternatively, skip saving and pass the URL and username directly when searching:

```sh
swift run calfind "Alice Chen" 2026-01-01 2026-01-31 \
  --caldav-url "https:\/\/caldav.example.com\/calendars\/me\/work\/" \
  --caldav-username "me@example.com" \
  --password-stdin
```

`--password-stdin` reads the password from standard input.

## Removing saved calendars

Saved URLs and usernames are stored in the config file; passwords are stored in the macOS Keychain. To remove all saved calendars and their Keychain credentials:

```sh
swift run calfind auth logout --all
```
