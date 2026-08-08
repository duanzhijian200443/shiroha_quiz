# ADR-004: Bank Identity for J0 Projects

Status: **Accepted**

## Context

The current database has no independent bank entity or stable bank identifier. A durable bank relation is derived from `questions.bank_name`, and `bank_folders`, T0, QuestionList, Practice, WrongBook and the current UI identify banks by name. Current behavior supports moving folders and destructive deletion, but not renaming a bank.

J0 needs Projects to reference existing banks without turning Project work into a bank-registry migration or reopening typed question persistence.

## Decision A

J0 uses the existing bank name as the Project-to-bank relation key.

J0 adds only these Project persistence concepts:

- `projects`;
- `project_files`;
- `project_banks`.

`project_banks` stores `bank_name`. In J0, this is a compatibility relation to the current name-based bank model, not a declaration that a bank name is a permanent stable identity.

## Why

This decision matches every current bank consumer and avoids introducing an independent bank authority before its lifecycle, compatibility and migration rules are designed. It keeps J0 additive: Projects can organize existing files and banks while the current question, folder and typed-content authorities remain unchanged.

## Compatibility

Existing banks remain valid without Project membership. Existing name-based behavior in `questions.bank_name`, `bank_folders`, T0, QuestionList, Practice, WrongBook and the UI remains authoritative for J0 bank lookup.

`bank_name` in `project_banks` is a temporary compatibility relation. It does not create a second bank entity, change question ownership, or replace existing bank deletion behavior.

Deleting a Project deletes only Project metadata and its file/bank relations. It must not delete questions, banks, folders, LibraryFiles, managed file bytes, typed sidecars or review state.

## Rename semantics

Bank rename is not supported in J0. J0 must not add a rename command, infer rename from relation updates, or attempt to cascade a bank-name change across questions, folders or Project relations.

Any future bank rename requires a separately authorized stable-identity design and migration.

## Migration consequence

A future stable bank ID migration must explicitly migrate the name-based relations in `questions.bank_name`, `bank_folders`, `project_banks` and affected consumers. That migration is not part of J0 and requires separate authorization.

The migration may change bank identity and relation storage, but it must not reconstruct, overwrite or demote the typed sidecar as content authority. Bank identity remains organizational metadata around persisted learning content.

## Explicit non-goals

J0 does not:

- create a `bank_registry` or another independent bank entity;
- assign stable IDs to existing banks;
- rename banks or define rename conflict handling;
- migrate current name-based consumers;
- change typed question content, sidecar authority, review state or FSRS state;
- change destructive bank deletion semantics;
- make Projects owners of banks, questions or LibraryFiles.

## J0 implementation boundary

J0 may implement `projects`, `project_files` and `project_banks`, with `project_banks.bank_name` referencing the current compatibility identity. Project operations may create and remove Project metadata and relations only.

Stable bank identity, bank rename, relation migration and changes to existing bank consumers remain outside J0 and require a separately authorized stage.
