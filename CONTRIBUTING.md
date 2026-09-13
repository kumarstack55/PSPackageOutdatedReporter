# Contributing

## Commit messages

This repository uses a lightweight version of Conventional Commits:

```text
<type>(<scope>): <short imperative description>
```

Use one of these types:

- `feat`: add a feature
- `fix`: correct a bug
- `refactor`: change code structure without changing behavior
- `test`: add or update tests
- `docs`: update documentation
- `chore`: make maintenance or configuration changes

The scope is optional. Use it when it makes the affected area clearer, such as `winget`, `chocolatey`, `scoop`, or `cache`.

Examples:

```text
feat(winget): report manifest release dates
fix(cache): handle invalid cache schema
refactor(providers): split manager-specific code
test(scoop): cover status parsing
docs: add staged refactoring plan
```

Keep each commit focused on one purpose. Write the subject in English using the imperative form, without an initial capital letter or a trailing period. Keep unrelated formatting or cleanup out of the commit.

Mark a breaking change with `!`, or explain it in the commit body using `BREAKING CHANGE:`.

## Validation

Run the tests from Windows PowerShell 5.1 before submitting changes:

```powershell
Invoke-Pester .\tests
```