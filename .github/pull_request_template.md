## What changed

<!-- Brief summary of the change. One or two sentences. -->

## Why

<!-- The problem this PR solves or the feature it adds. Link to an issue
     if one exists. -->

## How to test

<!-- Steps a reviewer can follow to verify the change works. For doc-only
     PRs, write "documentation only". For task file changes, name the
     specific playbook command that exercises the change. -->

## Checklist

- [ ] I read [CONTRIBUTING.md](../CONTRIBUTING.md)
- [ ] Task file changes include updates to the file's header docblock
      where relevant (PURPOSE, INPUTS, OUTPUTS, SIDE EFFECTS, etc.)
- [ ] Variable name changes are reflected in both `group_vars/all/main.yaml`
      AND the project's `ARCHITECTURE.md` variable reference table
- [ ] If this changes the bundle manifest schema, both `pull/` AND
      `push/` are updated in this PR (or a follow-up is linked)
- [ ] No `vault.yaml` is committed (only `vault.yaml.example`)
- [ ] CI passes (`yaml-lint`, `syntax-check`, `release-dry-run`)
