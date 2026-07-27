# TOON Integration — Token-Efficient Prompts

## What is TOON?

**TOON (Token-Oriented Object Notation)** is a compact encoding format for JSON data,
designed specifically for LLM prompts. It saves **~40% tokens** compared to JSON by
declaring array fields once and streaming data as rows.

- **Website:** https://toonformat.dev
- **GitHub:** https://github.com/toon-format/toon
- **Version pinned by this repo:** `@toon-format/toon` `^2.3.0` in `package.json`, resolved to **2.3.0** in `package-lock.json` (and installed at that version in `node_modules/`).

> **Status (2026-07-28, v1.26.7).** Both encoders in this document were run and their output compared during this review — see [Toolkit Integration](#toolkit-integration). TOON remains an **optional utility**: nothing on the account-unification, provider-alias, or launch paths calls it, and no toolkit script consumes its output.

## Why Use TOON?

| Format | Tokens | Accuracy | Notes |
|--------|--------|----------|-------|
| JSON | 100% | 75.0% | Verbose, repeats field names |
| **TOON** | **~60%** | **76.4%** | Compact, LLM-friendly guardrails |
| YAML | ~80% | 74.2% | Less compact than TOON |
| CSV | ~50% | 70.1% | No nested structure support |

> These figures — and the "Token Savings Examples" further down — are **upstream-published benchmarks** from toonformat.dev, reproduced here for orientation. They have **not** been re-measured by this repo: the toolkit ships no tokenizer, so it can measure characters but not tokens. Do not cite them as toolkit evidence.

## How TOON Works

### JSON (verbose)
```json
{"users": [
  {"id": 1, "name": "Alice", "role": "admin"},
  {"id": 2, "name": "Bob", "role": "user"},
  {"id": 3, "name": "Charlie", "role": "user"}
]}
```

### TOON (compact)
```yaml
users[3]{id,name,role}:
  1,Alice,admin
  2,Bob,user
  3,Charlie,user
```

**Savings:** Fields declared once, data streamed as rows. ~40% fewer tokens.

## Using TOON with Claude Code

### In System Prompts

When sending structured context to Claude Code, format it in TOON:

```markdown
Project files are listed in TOON format:

files[5]{name,size,type,modified}:
  lib.sh,18317,shell,2026-06-21
  install.sh,4806,shell,2026-06-21
  test_providers.sh,15000,shell,2026-06-21
  CHANGELOG.md,5000,markdown,2026-06-21
  README.md,3000,markdown,2026-06-21

Analyze the codebase structure and suggest improvements.
```

### In Tool Definitions

Format tool schemas in TOON for token efficiency:

```markdown
Available tools in TOON format:

tools[3]{name,description}:
  read_file,Read a file from disk
  write_file,Write content to a file
  search,Search codebase for patterns

Tool parameters:
  read_file: path (required)
  write_file: path (required), content (required)
  search: query (required), path (optional)
```

### In Conversation History

Compress structured data in conversation:

```markdown
Previous analysis results (TOON format):

issues[4]{file,line,severity,message}:
  lib.sh,45,warning,Unused variable
  install.sh,102,error,Missing quotes
  test.sh,78,info,Deprecated syntax
  config.json,12,warning,Unknown key
```

## Toolkit Integration

### CLI Utility (Node)

The toolkit includes a TOON utility at `scripts/toon.mjs`. It hard-requires
Node **plus** the `@toon-format/toon` package — `install.sh` step 1b runs
`npm install` for exactly this, softly (a missing `npm` is a warning, not a
failure, because the toolkit's core needs no Node).

```bash
# Encode JSON to TOON
node scripts/toon.mjs encode '{"users":[{"id":1,"name":"Alice"}]}'

# Decode TOON to JSON
node scripts/toon.mjs decode 'users[1]{id,name}: 1,Alice'

# Demo with sample data
node scripts/toon.mjs demo

# Encode / decode a file
node scripts/toon.mjs encode-file data.json
node scripts/toon.mjs decode-file data.toon
```

`install.sh` symlinks only `scripts/claude-*.sh` onto `PATH`, so `toon.mjs` is
**not** a `PATH` command — invoke it through `node <path>` as shown.

### Python Wrapper

For Python scripts, use `scripts/toon_encode.py`:

```bash
# Encode JSON string
python3 scripts/toon_encode.py '{"files":[{"name":"lib.sh","size":18317}]}'

# Encode from file
python3 scripts/toon_encode.py --file data.json

# Or from stdin
echo '{"data":[...]}' | python3 scripts/toon_encode.py
```

> **Gotcha — the wrapper degrades silently.** `toon_encode.py` shells out to
> `toon.mjs`; when `node` is missing, `toon.mjs` cannot be found, the call times
> out, or it exits non-zero, the wrapper falls back to its own YAML-like
> `fallback_encode` **without saying so**. That fallback is an approximation,
> not canonical TOON. Measured 2026-07-28 on the same input:
>
> ```
> # with node available                 # with node hidden from PATH
> users[2]{id,name,role}:               users:
>   1,Alice,admin                         [2]{id,name,role}:
>   2,Bob,user                            1,Alice,admin
>                                         2,Bob,user
> ```
>
> The fallback form does **not** round-trip — `node scripts/toon.mjs decode` on
> it reports `Error: Line 3: Missing colon after key`. If the encoding matters,
> confirm Node and the package are present first.

### Go Port

`scripts/toon/` is a standalone Go module (`module toonencode`, `go 1.26`)
that reimplements the encoder side of the Python wrapper. Its CLI is
argument-compatible with `toon_encode.py` — positional JSON, `--file`/`-f`,
stdin, and a `--compact` flag accepted as a no-op for parity.

```bash
cd scripts/toon && go test ./...      # ok  toonencode
cd scripts/toon && go build -o toonencode .
./scripts/toon/toonencode '{"users":[{"id":1,"name":"Alice","role":"admin"}]}'
```

Two facts to know before relying on it:

- **The binary is gitignored** (`scripts/toon/.gitignore` excludes `/toonencode`
  and `/bin/`) and **nothing builds it** — neither `install.sh` nor any other
  toolkit script references `toonencode`. Build it yourself if you want it.
- **Output matches the Node encoder** on the shared example, verified
  2026-07-28: both emit the identical three lines
  `users[2]{id,name,role}: / 1,Alice,admin / 2,Bob,user`.

### In Provider Aliases

When using provider aliases, TOON can reduce token consumption for:
- System prompts with structured context
- Tool definitions sent to models
- File listings and code analysis results
- Conversation history with structured data

**Note:** TOON formats the CONTENT of messages, not the API transport. The API
request body remains JSON (providers require it).

## Token Savings Examples

> **Provenance.** The three tables below are the upstream-published token
> figures (see the note under [Why Use TOON?](#why-use-toon)). They are
> illustrative, not toolkit measurements — this repo has no tokenizer.

### Measured locally (characters, not tokens) — 2026-07-28

The one thing this repo *can* measure is size on the wire. A real 10-row file
listing built from `scripts/claude-*.sh` and encoded with `node
scripts/toon.mjs encode-file`:

| Format | Bytes | Reduction |
|--------|-------|-----------|
| JSON (compact, no whitespace) | 665 | — |
| TOON | 370 | **44.4%** |

Characters are a proxy for tokens, not a substitute — the real ratio depends on
the tokenizer and on how field names tokenize. Reproduce it with
`node scripts/toon.mjs encode-file <your.json> | wc -c`.

### File Listing (10 files)

| Format | Tokens | Savings |
|--------|--------|---------|
| JSON | ~180 | — |
| TOON | ~110 | **39%** |

### Tool Definitions (5 tools)

| Format | Tokens | Savings |
|--------|--------|---------|
| JSON | ~250 | — |
| TOON | ~150 | **40%** |

### User Records (20 users)

| Format | Tokens | Savings |
|--------|--------|---------|
| JSON | ~600 | — |
| TOON | ~350 | **42%** |

## Best Practices

1. **Use for arrays of objects** — TOON excels at tabular data
2. **Declare fields once** — `{id,name,role}` header saves tokens
3. **Use inline primitives** — Strings, numbers, booleans in rows
4. **Fenced code blocks** — Wrap TOON in ` ```toon ` for clarity
5. **Show the format** — LLMs parse TOON naturally once they see the pattern

## Limitations

- **API transport unchanged** — Providers still require JSON in request bodies
- **Nested structures** — Deep nesting reduces savings
- **Mixed types** — Arrays with mixed types use expanded format
- **Model support** — Most models parse TOON naturally, but some may need examples

## References

### In this repo

- `scripts/toon.mjs` — Node CLI (`encode`, `decode`, `encode-file`, `decode-file`, `demo`, `help`).
- `scripts/toon_encode.py` — Python wrapper around it, with the silent YAML-like fallback described above.
- `scripts/toon/` — standalone Go module (`toonencode`): `encode.go`, `main.go`, `encode_test.go`, `testdata/inputs.json`. Binary gitignored; nothing builds it automatically.
- `scripts/tests/test_toon.sh` — hermetic suite coverage for `toon.mjs` + `toon_encode.py`. It **SKIPs (exit 0)** when `node` or `@toon-format/toon` is absent, so a green suite on a Node-less host proves nothing about TOON.
- `install.sh` step 1b — the soft `npm install` that supplies `@toon-format/toon`.

### Upstream

- [TOON Format Overview](https://toonformat.dev/guide/format-overview.html)
- [Using TOON with LLMs](https://toonformat.dev/guide/llm-prompts.html)
- [Benchmarks](https://toonformat.dev/guide/benchmarks.html)
- [Specification](https://toonformat.dev/reference/spec.html)
