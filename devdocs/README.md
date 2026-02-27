# `.robot.new/devdocs` — Technical Documentation Guide for Developers

## Why this directory exists

`devdocs/` contains implementation-level documentation for the `.robot.new` module. It covers internal data models, algorithms, file formats, code conventions, and technical specifications that developers need to understand, maintain, or extend the codebase.

This is the counterpart to `docs/`, which serves narrators, coordinators, and stakeholders.

## Who this documentation is for

This directory is for:

- developers implementing or modifying module functions,
- contributors writing tests or adding new features,
- maintainers debugging parsing, resolution, or write-path issues,
- AI assistants working with the codebase.

This directory is **not** for end-user workflows, operational runbooks, or business-level process descriptions.

## Documentation goal

Every document here should answer:

1. **What does this system do at the implementation level?**
2. **What data structures and formats are involved?**
3. **What are the invariants, edge cases, and failure modes?**
4. **How do the components interact (dependencies, call chains, data flow)?**
5. **Where does the authoritative behavior diverge from external rules or expectations?**

## Writing principles

1. **Start from architecture, not usage**
   Explain data flow, component relationships, and design decisions before showing invocations.

2. **Use precise technical language**
   Reference function names, file paths, parameter types, and object schemas directly. Prefer `Get-EntityState` over "the entity enrichment step".

3. **Document invariants and contracts**
   State what is guaranteed (e.g., "PUExceeded is unbounded", "`Gracze.md` is never written to") and what is not.

4. **Show algorithms, not just outcomes**
   Include pseudocode, computation steps, and worked examples with concrete numbers.

5. **Be explicit about edge cases and divergences**
   Document what happens with `$null` values, empty inputs, ambiguous matches, and where implementation differs from external rules.

6. **Keep terms consistent with the codebase**
   Use the same property names, tag names, and type identifiers that appear in the source code and object schemas.

## What to avoid

- Role-based language ("Narrator does...", "Coordinator checks...") — use function and parameter names instead
- Omitting failure modes and error handling behavior
- Vague descriptions where precise algorithms exist
- Duplicating the main `README.md` verbatim — reference it for object schemas and usage examples

If a business-level explanation is needed for context, keep it to one sentence and link to the corresponding `docs/` document.

## Recommended template for each document

Use this section order:

1. **Status** (normative specification, reference, guide)
2. **Scope** (what is covered / not covered)
3. **Glossary** (term definitions specific to this document, if needed)
4. **Architecture / Data Model** (components, data flow, file formats)
5. **Algorithm / Behavior** (step-by-step logic, pseudocode, formulas)
6. **Edge Cases** (boundary conditions, null handling, error paths)
7. **Divergences** (where implementation differs from external rules)
8. **Dependency Graph** (what calls what, dot-source chains)
9. **Testing** (which test files cover this area, mock patterns)
10. **Related Documents** (links to other devdocs, docs, or source files)

## Quality checklist before publishing

- Does the document accurately reflect the current implementation?
- Are function names, parameter names, and object properties correct?
- Are algorithms described with enough precision to verify against source code?
- Are edge cases and error handling documented?
- Is unnecessary operational/business-level narrative removed?

If any answer is "no", revise before publishing.

## Current documents

| Document | Coverage |
|---|---|
| [MIGRATION.md](MIGRATION.md) | Data model transition, entity registry format, session format generations, write operations, PU workflow, module structure |
| [PU.md](PU.md) | Normative PU computation specification: algorithm, overflow pools, diagnostics, divergences from rules |
| [SYNTAX.md](SYNTAX.md) | Code style guide: comment conventions, naming, .NET patterns, entity file syntax, error handling |
