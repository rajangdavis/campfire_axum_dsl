# Differential write checks

`run.py` replays scripted requests against Rails and this app, each started fresh on its own copy of a parity seed,
and compares what Rails does with what the port does:

- every step's status and `Location` (and, with `bodies=True`, its content type and body);
- after the steps, every table's rows, with the values two servers can never agree on masked: timestamps, bcrypt
  digests, random tokens and join codes, blob keys, client addresses, deactivation UUIDs (a scenario's `masks=` adds
  its own, such as a new bot token);
- the pages listed in `pages=`, as DOM trees (`domdiff.py`: attributes sorted, whitespace collapsed, CSRF values,
  ports, `?v=` timestamps and this run's epoch milliseconds masked); a `(path, frame)` page is fetched as that Turbo
  frame.

```sh
make build                                  # the app under test: /tmp/axum_dsl_target/debug/campfire
python3 test/differential/run.py test/differential/scenarios/rooms.py
python3 test/differential/run.py test/differential/scenarios/rooms.py directs/create/new   # one scenario
```

It needs Docker with the `campfire-reference` image (`../once-campfire-rust/parity/bin/reference build`) and the
parity seeds (`parity/bin/seed`). Rails listens on 3101 and the port on 4501. `PARITY_DIR`, `CANDIDATE_BIN`,
`CANDIDATE_CRATE` and `CANDIDATE_DATA` override where they are found. `CANDIDATE_DOCKER=1` runs the port from its image
(`make image`, or `CANDIDATE_IMAGE`) instead of the local build: the image's libvips is the reference's, so the image
variants (`scenarios/variants.py`) are byte for byte. The unfurl scenarios fetch live public pages,
so a site that changes between the two requests can differ; they reuse one pair of servers (`reuse=True`).

A/B mode checks a refactor against the build before it, with no Rails image: `REFERENCE_BIN=/path/to/old/campfire
REFERENCE_CRATE=/path/to/old/crate python3 test/differential/run.py scenarios/account.py` runs that binary in Rails'
place (port 3101), each scenario on fresh copies of the same seed, and compares the same steps, rows and pages.

The scenario files are one per area: first run, rooms, account, bots, the bot API, people, push and search,
unfurl, pages, webhooks and image variants. Each holds the success path and the refusals Rails gives (a member's 403, an inactive record's 404, a blank
body's 422 ...); the GAPS.md progress notes list what each run found.

A step's body may be raw bytes (a bot's curl: the real verb, no CSRF) or `("multipart", {fields})` (curl's `-F`; a
`("file", path)` value is a file part). Multipart bodies use a fixed boundary, so a raw multipart body is the same text on
both servers.

`fuzz_action_text_html/run.sh [seed] [count]` fuzzes axum_dsl's `action_text_html` against Rails' `ActionText::Content`
in the reference image (random markup, entities, CRLF, NUL, attachments); it prints how many bodies match.

`fuzz_image_variant/run.sh [seed] [count]` fuzzes axum_dsl's `image_variant` against Active Storage's variant processing
(ImageProcessing::Vips's resize_to_limit) inside the reference image, on the same libvips, comparing the bytes.
`fuzz_identify/run.sh [seed] [count]` fuzzes an upload's identified content type and analyzed metadata against Marcel and
ImageAnalyzer::Vips (random images, documents, archives, names and declared types).
