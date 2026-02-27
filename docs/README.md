# `.robot.new/docs` — Documentation Guide for End Users and Stakeholders

## Why this project exists

`.robot.new` helps the team keep the world and campaign data consistent across the repository.  
In practice, it supports day-to-day operations such as:

- keeping player and character records up to date,
- organizing session information in a consistent format,
- applying monthly PU updates fairly and consistently,
- tracking what was already processed to avoid duplicate work,
- sending operational notifications to the right people.

This means less manual correction, fewer missed updates, and clearer operational history.

## Who this documentation is for

This folder is for:

- narrators and coordinators,
- players involved in operations/reporting,
- project owners and stakeholders reviewing process quality.

This folder is **not** for low-level technical implementation details.

## Documentation goal

Every document here should answer:

1. **What outcome does this process deliver?**
2. **When should we use it?**
3. **Who is responsible?**
4. **What inputs are needed?**
5. **What is the expected result?**
6. **What can go wrong and how to react?**

## Writing principles

1. **Start from business value, not tooling**  
   Explain why the process matters before explaining steps.

2. **Use role-based language**  
   Write "Narrator does...", "Coordinator checks...", "Player receives..." instead of script/function names.

3. **Preserve logic, simplify wording**  
   Keep the real sequence and rules, but describe them in plain language.

4. **Prefer concrete examples**  
   Show realistic scenarios ("monthly PU update", "new character onboarding") instead of abstract cases.

5. **Be explicit about decisions and side effects**  
   Clearly say what gets updated, what gets notified, and what gets logged.

6. **Keep terms consistent**  
   Use the same wording for core concepts (session, character, PU, notification, history/log).

## What to avoid

- Internal architecture and parser internals
- Function-level or file-level implementation deep-dives
- Raw object schemas and data model internals
- "Magic numbers" or abstract values without context
- CLI-focused instructions as the main narrative

If a technical detail is required for correctness, include only the minimum needed to understand decisions.

## Recommended template for each document

Use this section order:

1. **Purpose** (one short paragraph)
2. **Scope** (what is included / excluded)
3. **Actors and responsibilities**
4. **Inputs required**
5. **Step-by-step flow**
6. **Expected outcomes**
7. **Exceptions and recovery actions**
8. **Audit trail / evidence of completion**
9. **Related documents**

## Quality checklist before publishing

- Is the text understandable for a non-technical reader?
- Does it describe the real operational flow end-to-end?
- Are responsibilities and expected outputs unambiguous?
- Are exceptions and retry paths documented?
- Is unnecessary implementation detail removed?

If any answer is "no", revise before publishing.
