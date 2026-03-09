# Session Integrity

## Purpose

This guide explains how coordinators can verify that session file content has not been tampered with, accidentally corrupted, or improperly formatted. The integrity system creates a fingerprint of every session at a known-good point in time, then compares current content against those fingerprints to detect changes.

## Scope

**What is included:**

- Building and updating a hash store of all session headers and their content
- Detecting sessions whose content was modified since the last hash update
- Detecting sessions that were deleted from or added to files
- Flagging modified sessions that contain PU data (potential score manipulation)
- Detecting duplicate PU sections within a single session (tamper indicator)
- Identifying improperly formatted session headers (missing or invalid dates)
- Catching date-like lines that are missing the required `###` header prefix
- Flagging sessions with dates set in the future

**What is excluded:**

- Modifying session content (see [Sessions.md](Sessions.md))
- Running PU assignments (see [PU.md](PU.md))
- Verifying PU calculation correctness (see [PU.md](PU.md))
- Currency reconciliation (see [World-State.md](World-State.md))

## Actors and Responsibilities

### Coordinator

- Sets session hashes after each PU processing cycle to record the known-good state
- Runs session integrity test before PU processing to verify no unauthorized changes occurred
- Investigates any flagged issues before proceeding with PU assignments
- Pays special attention to PU-affected findings (highest severity)

### Narrator

- Does not interact with the integrity system directly
- Should follow proper session formatting (see [Sessions.md](Sessions.md)) to avoid false positives

## Building the Hash Store

Before the integrity system can detect changes, a baseline must be established.

**When to use:**

- After completing a PU processing cycle (to lock in the known-good state)
- When setting up the integrity system for the first time (`-Full` flag required)
- After deliberate, authorized edits to session files

**What you provide:**

- `-Full` flag for a complete scan of all repository files
- Optionally, `-File` to limit to specific files after targeted edits
- Optionally, `-ExcludeDirectory` to skip directories that should not be tracked

**What happens:**

- Every Markdown file in the repository is parsed
- Each session header and its content receive a unique fingerprint (SHA256 hash)
- Fingerprints are stored in a sidecar file structure alongside the repository
- A timestamp is recorded so future incremental runs only process recently changed files

**What you see:**

A summary showing how many files were processed, how many fingerprints were computed, and how many were new or updated compared to the previous run.

## Validating Integrity

**When to use:**

- Before every PU processing cycle
- Whenever you suspect unauthorized edits
- As a periodic health check on the session archive

**What you provide:**

- No flags needed for an incremental check (only recently changed files)
- `-Full` flag for a comprehensive check of all files
- Optionally, `-File` to check specific files

**What you see:**

A diagnostic report with an overall pass/fail status and categorized findings:

### 1. Modified Sessions

Sessions whose content differs from the stored fingerprint. This could indicate legitimate edits that need a hash update, or unauthorized tampering.

**Example questions this answers:**
- "Has anyone changed session content since the last PU run?"
- "Were any PU values altered after processing?"

### 2. Deleted Sessions

Sessions that were in the hash store but are no longer present in the file. This could indicate accidental deletion or intentional removal.

**Example questions this answers:**
- "Did any sessions disappear from the archive?"

### 3. New Sessions

Sessions present in the file but not in the hash store. Expected after adding new sessions; unexpected if no new sessions were authored.

**Example questions this answers:**
- "Were new sessions added since the last hash update?"

### 4. Missing Hash Files

Markdown files that have no corresponding fingerprint record. Expected for newly created files; unexpected for established archive files.

**Example questions this answers:**
- "Are there files we have never fingerprinted?"

### 5. Malformed Headers

Session headers (level-3 `###` lines) that do not contain a valid date in `YYYY-MM-DD` format. These sessions cannot be properly parsed by the system.

**Example questions this answers:**
- "Are there session headers with typos or formatting errors?"

### 6. PU-Affected Sessions (High Severity)

A subset of modified sessions that contain PU data. Changes to PU values after a processing cycle may indicate score manipulation and warrant immediate investigation.

**Example questions this answers:**
- "Were any PU values changed after the last processing run?"

### 7. Duplicate PU Markers (High Severity)

Sessions containing two or more `@PU:` section markers. A legitimate session should have at most one PU section. Duplicates may indicate an attempt to inject additional PU awards.

**Example questions this answers:**
- "Does any session have duplicate PU entries?"

### 8. Format Anomalies

Lines that look like session dates (`YYYY-MM-DD`) but are not preceded by the required `### ` header prefix. These lines will not be recognized as sessions by the parser.

**Example questions this answers:**
- "Are there sessions that were written without the correct header format?"

### 9. Future-Dated Sessions

Session headers with dates set after today. Sessions should only record events that have already occurred.

**Example questions this answers:**
- "Has someone created a session with a future date?"

## Expected Outcomes

1. Before each PU processing run, the coordinator runs a validation check
2. If the report shows `OK = True`, all session content matches stored fingerprints — safe to proceed
3. If the report shows findings, the coordinator investigates each category
4. PU-affected and duplicate PU findings take priority and must be resolved before processing
5. After investigation and any corrections, the coordinator updates the hash store
6. After PU processing completes, the coordinator updates the hash store again to record the new baseline

## Exceptions and Recovery Actions

| Situation | What happens | Recovery |
|---|---|---|
| **First run with no hash store** | All files reported as "Missing Hash Files" | Run a full hash build to create the initial baseline |
| **Legitimate session edit after hashing** | Modified session flagged | Verify the edit was authorized, then re-hash the affected file |
| **New session file added** | Missing hash file reported | Hash the new file to add it to the store |
| **Git changelog unavailable** | Incremental mode falls back to full scan | No action needed — automatic fallback |
| **Corrupt hash sidecar file** | Treated as empty — all headers flagged as new | Re-hash the affected file to regenerate |
| **PU-affected finding** | Session with PU data was modified | Investigate immediately — compare current vs. expected PU values before proceeding |
| **Duplicate PU markers** | Session has 2+ PU blocks | Investigate for tampering — remove the duplicate section and re-hash |
| **Future-dated session** | Session date is after today | Verify with the narrator — correct the date if it was a mistake |

## Related Documents

- [Sessions.md](Sessions.md) — session format and recording rules
- [PU.md](PU.md) — PU assignment processing
- [Auditing.md](Auditing.md) — other audit and reporting tools
- [Troubleshooting.md](Troubleshooting.md) — general diagnostic guidance
