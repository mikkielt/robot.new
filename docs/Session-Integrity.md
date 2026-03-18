# Session Integrity

## Overview

The integrity system creates a fingerprint of every session at a known-good point in time, then compares current content against those fingerprints to detect changes. Coordinators use it to verify that session file content has not been tampered with, accidentally corrupted, or improperly formatted.

## Actors and Responsibilities

The Coordinator sets session hashes after each PU processing cycle to record the known-good state, runs the session integrity test before PU processing to verify no unauthorized changes occurred, investigates any flagged issues before proceeding with PU assignments, and pays special attention to PU-affected findings (highest severity).

The Narrator follows proper session formatting (see [Sessions.md](Sessions.md)) to avoid false positives. Narrators do not interact with the integrity system directly.

## Building the Hash Store

Before the integrity system can detect changes, a baseline must be established. Build the hash store after completing a PU processing cycle (to lock in the known-good state), when setting up the integrity system for the first time (full scan required), or after deliberate, authorized edits to session files.

The Coordinator can request a complete scan of all repository files, limit the scan to specific files after targeted edits, or exclude directories that should not be tracked.

Every Markdown file in the repository is parsed. Each session header and its content receive a unique fingerprint (SHA256 hash). Fingerprints are stored in a sidecar file structure alongside the repository. A timestamp is recorded so future incremental runs only process recently changed files.

The output is a summary showing how many files were processed, how many fingerprints were computed, and how many were new or updated compared to the previous run.

## Validating Integrity

Run validation before every PU processing cycle, whenever you suspect unauthorized edits, or as a periodic health check on the session archive.

An incremental check covers only recently changed files and requires no additional options. A comprehensive check covers all files, and a targeted check covers specific files.

During the check, a progress indicator shows how many files have been processed so far (e.g., "35/120"), with a spinner and elapsed time. When the check completes, a diagnostic report appears with an overall pass/fail status and categorized findings.

## Finding Categories

The diagnostic report groups findings into nine categories.

Modified sessions are sessions whose content differs from the stored fingerprint. This could indicate legitimate edits that need a hash update, or unauthorized tampering. This category answers questions like "Has anyone changed session content since the last PU run?" and "Were any PU values altered after processing?"

Deleted sessions are sessions that were in the hash store but are no longer present in the file. This could indicate accidental deletion or intentional removal.

New sessions are sessions present in the file but absent from the hash store. These are expected after adding new sessions and unexpected if no new sessions were authored.

Missing hash files are Markdown files that have no corresponding fingerprint record. These are expected for newly created files and unexpected for established archive files.

Malformed headers are session headers (level-3 `###` lines) that do not contain a valid date in `YYYY-MM-DD` format. These sessions cannot be properly parsed by the system.

PU-affected sessions (high severity) are a subset of modified sessions that contain PU data. Changes to PU values after a processing cycle may indicate score manipulation and warrant immediate investigation.

Duplicate PU markers (high severity) are sessions containing two or more `@PU:` section markers. A legitimate session has at most one PU section. Duplicates may indicate an attempt to inject additional PU awards.

Format anomalies are lines that look like session dates (`YYYY-MM-DD`) but are missing the required `### ` header prefix. These lines will not be recognized as sessions by the parser.

Future-dated sessions are session headers with dates set after today. Sessions should only record events that have already occurred.

## Expected Outcomes

1. Before each PU processing run, the Coordinator runs a validation check
2. If the report shows OK = True, all session content matches stored fingerprints — safe to proceed
3. If the report shows findings, the Coordinator investigates each category
4. PU-affected and duplicate PU findings take priority and must be resolved before processing
5. After investigation and any corrections, the Coordinator updates the hash store
6. After PU processing completes, the Coordinator updates the hash store again to record the new baseline

## Exceptions and Recovery Actions

| Situation | What happens | Recovery |
|---|---|---|
| First run with no hash store | All files reported as "Missing Hash Files" | Run a full hash build to create the initial baseline |
| Legitimate session edit after hashing | Modified session flagged | Verify the edit was authorized, then re-hash the affected file |
| New session file added | Missing hash file reported | Hash the new file to add it to the store |
| Git changelog unavailable | Incremental mode falls back to full scan | No action needed — automatic fallback |
| Corrupt hash sidecar file | Treated as empty — all headers flagged as new | Re-hash the affected file to regenerate |
| PU-affected finding | Session with PU data was modified | Investigate immediately — compare current vs. expected PU values before proceeding |
| Duplicate PU markers | Session has 2+ PU blocks | Investigate for tampering — remove the duplicate section and re-hash |
| Future-dated session | Session date is after today | Verify with the narrator — correct the date if it was a mistake |

## Related Documents

- [Sessions.md](Sessions.md) — Session format and recording rules
- [PU.md](PU.md) — PU assignment processing
- [Auditing.md](Auditing.md) — Other audit and reporting tools
- [Troubleshooting.md](Troubleshooting.md) — General diagnostic guidance
