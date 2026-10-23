# grabbit-telegram-helper

Separate-process Telegram MTProto helper for Grabbit's Telegram browser. It owns
the account session and network connection; Grabbit only exchanges
line-oriented commands/results over stdout/stderr.

The app uses the persistent `-serve` worker for chats, messages, previews, and
downloads. The one-shot modes remain available for diagnostics and for
operations that must run with the worker stopped (`-status`, `-login`,
`-logout`).

## Build

Local development credentials live in `~/.config/grabbit/telegram.env`
(permissions `0600`) and are read by the helper at runtime; they are **not**
baked into debug builds:

```
TELEGRAM_API_ID=...
TELEGRAM_API_HASH=...
```

Build and install into the app bundle:

```sh
scripts/vendor-telegram-helper.sh
```

For a release build, inject Grabbit's app-level credentials at link time so
users never enter an API ID/hash:

```sh
TELEGRAM_API_ID=... TELEGRAM_API_HASH=... scripts/vendor-telegram-helper.sh
```

The script passes them to `-X main.defaultAPIID` / `-X main.defaultAPIHash`.
Credentials baked into a release binary are recoverable by anyone who has the
binary; that is normal for desktop Telegram clients. Telegram has no
self-service API hash reset/revoke: if the pair leaks, contact
`recover@telegram.org` or `support@telegram.org`, and never commit the env file
or paste the hash into an issue/chat.

## One-shot commands

- `-status` — `AUTHORIZED` or `UNAUTHORIZED`
- `-login` — QR login; prints `QR_URL=...`, then `AUTH_OK`
- `-logout` — revoke and remove the local session
- `-chats` — JSON chat list
- `-messages <peer> -limit N` — JSON recent media messages
- `-download -peer <peer> -message <id> -out <path>`
  - `-threads N` controls parallel `upload.getFile` connections (default 4,
    clamped to 1–8; small files automatically use one). Parallel chunks improve
    throughput on multi-megabyte video/audio.
- `-delete -peer <peer> -message <id>`
- `-self-test`, `-self-upload` — Saved Messages diagnostics

When two-step verification is enabled, `-login` prints `NEED_2FA=1` and keeps
the QR-approved process alive. The app sends one password line over stdin; an
incorrect password re-prompts on the same process (preserving the QR login)
instead of showing a new QR. CLI callers can still use the
`TELEGRAM_2FA_PASSWORD` environment variable or the `-password` flag.

## Persistent worker (`-serve`)

`grabbit-telegram-helper -serve` opens the session once, prints a single
`READY` line, and then reads tab-delimited commands from stdin until `QUIT` or
EOF. It is the only process that should touch the session while it is running.

Startup:

```
READY
```

Commands are `<COMMAND>\t<request-id>[\t<arg>...]`. Request ids are chosen by
the caller and must be unique for the life of the worker. Arguments must not
contain tabs or newlines; Grabbit sanitizes filenames before sending them.
A `<peer>` argument is `self`, `@username`, or a type-qualified numeric id
(`user:123`, `group:456`, `channel:789`). The qualifier prevents collisions
between Telegram's peer id namespaces; plain numeric ids remain accepted for
older callers.

| Command | Arguments | Result |
| --- | --- | --- |
| `PING` | — | `OK` (liveness/readiness probe) |
| `CHATS` | — | JSON chat list |
| `MESSAGES` | `<peer>` `<limit>` | JSON media messages |
| `DOWNLOAD` | `<peer>` `<message-id>` `<output-path>` `<threads>` | `OK` with `<bytes>\t<sha256>` |
| `WARM` | `<peer>` `<message-id>` | `OK` after a 4 KiB read |
| `WARM_PEER` | `<peer>` `<limit>` | `OK` with the number of file DCs warmed |
| `CANCEL` | `<request-id>` | No result of its own; cancels that request |
| `QUIT` | `<request-id>` | Cancels outstanding work, waits for it, exits |

Output lines are one of:

```
PROGRESS\t<request-id>\t<written-bytes>\t<total-bytes>
RESULT\t<request-id>\tOK[\t<payload>]
RESULT\t<request-id>\tERR\t<single-line-error>
```

`PROGRESS` is emitted only for `DOWNLOAD`. The final `RESULT` always follows;
`OK` with a tab-separated payload is used by `DOWNLOAD` (size and SHA-256) and
`WARM_PEER` (count). `CANCEL` may arrive before the worker has started the
corresponding command; the server remembers the id so the request exits without
doing unnecessary network work.

Warm-up reads are deliberately small (4 KiB) and discarded. Grabbit sends
`WARM_PEER` after loading a chat's messages, once per unique file datacenter.
This opens the file-DC sub-connections so the first user-visible download does
not pay the multi-second `FILE_MIGRATE` handshake. Warm-up never writes a
preview or download file.

Previews use the same `DOWNLOAD` command into a unique `.partial` staging file
in Grabbit's preview cache. When the viewer closes, Grabbit sends `CANCEL`; the
helper stops the transfer and Grabbit deletes the staging file. A completed
cache entry is kept. Nothing from a preview is written to `~/Downloads`.

Example worker smoke test (the `QUIT` request id is required by the parser):

```sh
printf 'PING\t1\nQUIT\t2\n' | Grabbit/Resources/bin/grabbit-telegram-helper -serve
```

## Storage and safety

- Session: `~/Library/Application Support/Grabbit/Telegram/session.json` (`0600`)
- Peer cache: `~/Library/Application Support/Grabbit/Telegram/peers.json` (`0600`)
- Previews: `~/Library/Caches/Grabbit/TelegramPreviews/`
- Downloads: `~/Downloads/Grabbit/Telegram/<channel>/`
- The helper only downloads files the signed-in account can access. Grabbit's
  UI asks the user to confirm batch downloads and to use only authorized media.
- The app stops the worker before running `-logout`, so the session is never
  accessed by two helper processes at once. `-status` is safe before the worker
  starts.
- This is a clean-room helper built on `gotd/td` (MIT). It does not include
  OmniGet code, assets, or credentials.
