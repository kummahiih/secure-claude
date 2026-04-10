# Design Doc: Copy-Paste Fix — Test Wiring, copy_file, diff_files

## 1. Problem Statement

A plan was produced that added Go unit tests to `cluster/agent/fileserver/mcp_test.go`
but **never included a task to wire those tests into `test.sh`** (the only script
`tester-server` will execute). As a result, `run_tests` passed without exercising
the new code. The agent consumed tokens writing and iterating on tests that were
silently ignored, and the final commit falsely appeared green.

A secondary waste: the agent repeatedly copied boilerplate between handler
implementations by reading the whole file, mentally diffing, and writing it back.
A `copy_file` tool and a `diff_files` tool would halve the round-trips for that class
of task.

---

## 2. Root Causes

### 2a. Plan prompt does not mandate test tasks

`cluster/agent/prompts/system/plan.md` requires `verify` to include
`"run_tests passes"` but does **not** require:

- Every code task to have a paired test task in the same plan.
- Plans that add new test files to include an explicit **"wire tests"** task that
  ensures `test.sh` invokes the new file.

The planner can therefore generate a valid-looking plan that leaves new tests
permanently disconnected from the CI gate.

### 2b. No `copy_file` tool in the fileserver

Copying a file currently requires:
1. `read_workspace_file` (full content, potentially large, token-expensive)
2. `write_file` or `create_file` + `write_file`

That is two round-trips plus full file content in the context window. A single
`copy_file(src, dst)` call on the server side is O(bytes) without any LLM token
cost for content.

### 2c. No `diff_files` tool in the fileserver

When reviewing a change or verifying a template was applied correctly, the agent
must read two files in full and mentally diff them. A `diff_files(path_a, path_b)`
returning a unified diff is far cheaper and more precise.

---

## 3. Fixes

### Fix A — Amend `cluster/agent/prompts/system/plan.md`

Add two mandatory rules to the **Task requirements** section:

1. **Every task that creates or modifies source code MUST be paired with a task
   that creates or updates the corresponding test file in the same plan.**
   The test task must be listed immediately after its source task.

2. **Every plan that introduces new test files MUST include a final
   "Wire tests" task** whose `action` explicitly names the test file(s) and
   verifies they are invoked by `test.sh`. The `verify` field of that task must
   confirm `run_tests passes` AND that the new test names appear in the test
   runner output.

These additions close the gap where a planner can produce a structurally valid
plan that silently skips test registration.

---

### Fix B — Add `copy_file` to the Go fileserver

**New REST endpoint:** `POST /copy`  
**Request body (JSON):**
```json
{"src": "relative/path/source.go", "dst": "relative/path/dest.go"}
```
**Responses:**
- `200 OK` — copy succeeded
- `400 Bad Request` — missing or empty `src`/`dst`
- `404 Not Found` — `src` does not exist or is outside jail
- `409 Conflict` — `dst` already exists (overwrite must be explicit; see below)
- `500 Internal Server Error` — I/O failure

**Behaviour:**
- Both `src` and `dst` are resolved through `os.Root` — path traversal is
  structurally impossible.
- The handler reads `src` entirely into memory and writes to `dst` with
  `O_CREATE|O_EXCL` (no-overwrite by default). An optional `"overwrite": true`
  field in the body switches to `O_CREATE|O_TRUNC`.
- Directories are not supported; `src` must be a regular file.

**Go unit tests** (in `cluster/agent/fileserver/mcp_test.go`,
`TestMCPHandlers` sub-tests):
- `Copy: happy path copies content` — write src, copy to dst, read dst, assert identical.
- `Copy: overwrite=true replaces existing dst` — pre-create dst with different
  content, copy with overwrite, verify new content.
- `Copy: missing src returns 404`
- `Copy: dst already exists without overwrite returns 409`
- `Copy: path traversal on src is rejected` — `src=../etc/passwd`
- `Copy: path traversal on dst is rejected` — `dst=../etc/evil`

**MCP tool registration** (in `cluster/agent/mcp/files_mcp.py`):
- Add `copy_file` to `list_tools()` with schema `{src: string, dst: string,
  overwrite?: boolean}`.
- Add branch in `_dispatch()` that posts to `{MCP_SERVER_URL}/copy`.
- Add Python unit tests in `cluster/agent/mcp/files_mcp_test.py`:
  `test_copy_file_success`, `test_copy_file_overwrite_success`,
  `test_copy_file_not_found`, `test_copy_file_conflict`.

---

### Fix C — Add `diff_files` to the Go fileserver

**New REST endpoint:** `GET /diff?a=<path>&b=<path>`  
**Responses:**
- `200 OK` — body is a unified diff (empty string if files are identical)
- `400 Bad Request` — missing `a` or `b`
- `404 Not Found` — either path does not exist or is outside jail
- `500 Internal Server Error` — I/O failure

**Behaviour:**
- Both paths are resolved through `os.Root`.
- Diff is computed in-process (no `diff` binary dependency) using a simple
  line-by-line Myers-diff or the standard `github.com/sergi/go-diff` package if
  available; otherwise fall back to a manual unified-diff implementation that is
  already permissible under the project's module requirements.
- Output format: standard unified diff (`--- a/path`, `+++ b/path`, `@@ ... @@`
  hunks), 3-line context.
- If files are identical, returns `200` with an empty body.

**Go unit tests** (in `cluster/agent/fileserver/mcp_test.go`):
- `Diff: identical files returns empty body`
- `Diff: changed lines returns unified diff with correct hunks`
- `Diff: missing file a returns 404`
- `Diff: path traversal on a is rejected`
- `Diff: path traversal on b is rejected`

**MCP tool registration** (in `cluster/agent/mcp/files_mcp.py`):
- Add `diff_files` to `list_tools()` with schema `{path_a: string, path_b: string}`.
- Add branch in `_dispatch()` that GETs `{MCP_SERVER_URL}/diff?a=...&b=...`.
- Add Python unit tests in `cluster/agent/mcp/files_mcp_test.py`:
  `test_diff_files_identical`, `test_diff_files_changed`, `test_diff_files_not_found`.

---

## 4. Ordered Actionable Task List

Each task touches at most 2 files, has a concrete verify step, and is completable
in ≤ 8 LLM round-trips.

---

### Task 1 — Amend plan system prompt to mandate test pairing and wire task

**Files:**
- `cluster/agent/prompts/system/plan.md`

**Action:**  
In the **Task requirements** section, append two bullet points:
1. Every task that creates or modifies source code MUST be immediately followed by
   a paired task that creates or updates the corresponding tests.
2. Every plan introducing new test files MUST include a final "Wire tests" task
   whose `action` names the test files and confirms they are invoked by `test.sh`;
   `verify` must state that `run_tests passes` and that the new test names appear
   in output.

**Verify:** `run_tests passes`; grep `cluster/agent/prompts/system/plan.md` for
"Wire tests" and "paired".

---

### Task 2 — Implement `handleCopy` in Go fileserver

**Files:**
- `cluster/agent/fileserver/main.go`

**Action:**  
Add `handleCopy(rootDir *os.Root, token string) http.HandlerFunc` implementing
`POST /copy` as specified in Fix B. Register it in `setupRouter` as
`mux.HandleFunc("/copy", handleCopy(rootDir, token))`.

**Verify:** `go build ./...` succeeds in `cluster/agent/fileserver/`.

---

### Task 3 — Add Go unit tests for `handleCopy`

**Files:**
- `cluster/agent/fileserver/mcp_test.go`

**Action:**  
Add the six sub-tests listed in Fix B inside `TestMCPHandlers`:
happy path, overwrite, missing src (404), dst exists without overwrite (409),
traversal on src rejected, traversal on dst rejected.

**Verify:** `run_tests passes`; `go test ./...` in fileserver shows all Copy
sub-tests passing.

---

### Task 4 — Implement `handleDiff` in Go fileserver

**Files:**
- `cluster/agent/fileserver/main.go`

**Action:**  
Add `handleDiff(rootDir *os.Root, token string) http.HandlerFunc` implementing
`GET /diff` as specified in Fix C. Use an in-process line-by-line unified diff
(no external binary). Register it in `setupRouter` as
`mux.HandleFunc("/diff", handleDiff(rootDir, token))`.

**Verify:** `go build ./...` succeeds.

---

### Task 5 — Add Go unit tests for `handleDiff`

**Files:**
- `cluster/agent/fileserver/mcp_test.go`

**Action:**  
Add the five sub-tests listed in Fix C inside `TestMCPHandlers`:
identical files returns empty body, changed lines returns unified diff,
missing file a (404), traversal on a rejected, traversal on b rejected.

**Verify:** `run_tests passes`; Copy and Diff sub-tests both pass.

---

### Task 6 — Register `copy_file` MCP tool in `files_mcp.py`

**Files:**
- `cluster/agent/mcp/files_mcp.py`

**Action:**  
In `list_tools()`, add a `types.Tool` for `copy_file` with schema
`{src: string, dst: string, overwrite?: boolean}`.  
In `_dispatch()`, add an `elif name == "copy_file":` branch that POSTs to
`{MCP_SERVER_URL}/copy` with JSON body `{src, dst, overwrite}` and maps
200 → success message, 404 → `FileNotFoundError`, 409 → `FileExistsError`,
other → `RuntimeError`.

**Verify:** `run_tests passes`.

---

### Task 7 — Add Python unit tests for `copy_file` in `files_mcp_test.py`

**Files:**
- `cluster/agent/mcp/files_mcp_test.py`

**Action:**  
Add four async test functions (decorated with `@patch("files_mcp.requests.post")`):
`test_copy_file_success` (200), `test_copy_file_overwrite_success` (200 with
`overwrite=True`), `test_copy_file_not_found` (404 raises `FileNotFoundError`),
`test_copy_file_conflict` (409 raises `FileExistsError`).

**Verify:** `run_tests passes`; `pytest files_mcp_test.py` shows the four new
tests passing.

---

### Task 8 — Register `diff_files` MCP tool in `files_mcp.py`

**Files:**
- `cluster/agent/mcp/files_mcp.py`

**Action:**  
In `list_tools()`, add a `types.Tool` for `diff_files` with schema
`{path_a: string, path_b: string}`.  
In `_dispatch()`, add an `elif name == "diff_files":` branch that GETs
`{MCP_SERVER_URL}/diff` with params `a=path_a, b=path_b` and maps
200 → response text (empty string if identical), 404 → `FileNotFoundError`,
other → `RuntimeError`.

**Verify:** `run_tests passes`.

---

### Task 9 — Add Python unit tests for `diff_files` in `files_mcp_test.py`

**Files:**
- `cluster/agent/mcp/files_mcp_test.py`

**Action:**  
Add three async test functions (decorated with `@patch("files_mcp.requests.get")`):
`test_diff_files_identical` (200, empty body → returns `""`),
`test_diff_files_changed` (200, body contains `---`/`+++` lines),
`test_diff_files_not_found` (404 raises `FileNotFoundError`).

**Verify:** `run_tests passes`; `pytest files_mcp_test.py` shows all three new
tests passing.

---

### Task 10 — Wire new Go tests into `test.sh` (if not already wired)

**Files:**
- `test.sh`

**Action:**  
Confirm that `test.sh` runs `go test ./...` (or equivalent) in
`cluster/agent/fileserver/`. If the Copy and Diff sub-tests are not already
executed, add the invocation. Confirm that `pytest` in `cluster/agent/claude/`
covers `files_mcp_test.py`.

**Verify:** `run_tests passes`; output of the test run contains
`TestMCPHandlers/Copy:` and `TestMCPHandlers/Diff:` sub-test names, plus
`test_copy_file_success` and `test_diff_files_identical` in pytest output.
