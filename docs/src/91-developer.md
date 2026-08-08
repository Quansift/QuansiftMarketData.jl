# [Developer documentation](@id dev_docs)

!!! note "Contributing guidelines"
    If you haven't, please read the [Contributing guidelines](90-contributing.md) first.

If you want to make contributions to this package that involves code, then this guide is for you.

## First time clone

!!! tip "If you have writing rights"
    If you have writing rights, you don't have to fork. Instead, simply clone and skip ahead. Whenever **upstream** is mentioned, use **origin** instead.

If this is the first time you work with this repository, follow the instructions below to clone the repository.

1. Fork this repo
2. Clone your repo (this will create a `git remote` called `origin`)
3. Add this repo as a remote:

   ```bash
   git remote add upstream https://github.com/Quansift/Tiingo.jl
   ```

This will ensure that you have two remotes in your git: `origin` and `upstream`.
You will create branches and push to `origin`, and you will fetch and update your local `main` branch from `upstream`.

## Linting and formatting

Install a plugin on your editor to use [EditorConfig](https://editorconfig.org).
This will ensure that your editor is configured with important formatting settings.

We use [https://pre-commit.com](https://pre-commit.com) to run the linters and formatters.
In particular, the Julia code is formatted using [JuliaFormatter.jl](https://github.com/domluna/JuliaFormatter.jl), so please install it globally first:

```julia-repl
julia> # Press ]
pkg> activate
pkg> add JuliaFormatter
```

To install `pre-commit`, we recommend using [pipx](https://pipx.pypa.io) as follows:

```bash
# Install pipx following the link
pipx install pre-commit
```

With `pre-commit` installed, activate it as a pre-commit hook:

```bash
pre-commit install
```

To run the linting and formatting manually, enter the command below:

```bash
pre-commit run -a
```

**Now, you can only commit if all the pre-commit tests pass**.

## Testing

As with most Julia packages, you can just open Julia in the repository folder, activate the environment, and run `test`:

```julia-repl
julia> # press ]
pkg> activate .
pkg> test
```

## Working on a new issue

We try to keep a linear history in this repo, so it is important to keep your branches up-to-date.

1. Fetch from the remote and fast-forward your local main

   ```bash
   git fetch upstream
   git switch main
   git merge --ff-only upstream/main
   ```

2. Branch from `main` to address the issue (see below for naming)

   ```bash
   git switch -c 42-add-answer-universe
   ```

3. Push the new local branch to your personal remote repository

   ```bash
   git push -u origin 42-add-answer-universe
   ```

4. Create a pull request to merge your remote branch into the org main.

### Branch naming

- If there is an associated issue, add the issue number.
- If there is no associated issue, **and the changes are small**, add a prefix such as "typo", "hotfix", "small-refactor", according to the type of update.
- If the changes are not small and there is no associated issue, then create the issue first, so we can properly discuss the changes.
- Use dash separated imperative wording related to the issue (e.g., `14-add-tests`, `15-fix-model`, `16-remove-obsolete-files`).

### Commit message

- Use imperative or present tense, for instance: *Add feature* or *Fix bug*.
- Have informative titles.
- When necessary, add a body with details.
- If there are breaking changes, add the information to the commit message.

### Before creating a pull request

!!! tip "Atomic git commits"
    Try to create "atomic git commits" (recommended reading: [The Utopic Git History](https://blog.esciencecenter.nl/the-utopic-git-history-d44b81c09593)).

- Make sure the tests pass.
- Make sure the pre-commit tests pass.
- Fetch any `main` updates from upstream and rebase your branch, if necessary:

  ```bash
  git fetch upstream
  git rebase upstream/main BRANCH_NAME
  ```

- Then you can open a pull request and work with the reviewer to address any issues.

## Building and viewing the documentation locally

Following the latest suggestions, we recommend using `LiveServer` to build the documentation.
Here is how you do it:

1. Run `julia --project=docs` to open Julia in the environment of the docs.
1. If this is the first time building the docs
   1. Press `]` to enter `pkg` mode
   1. Run `pkg> dev .` to use the development version of your package
   1. Press backspace to leave `pkg` mode
1. Run `julia> using LiveServer`
1. Run `julia> servedocs()`

## Making a new release

Release validation has three intentionally different modes.

- Development mode runs in ordinary CI and directly with
  `julia --project=. scripts/ci/validate_release_hygiene.jl`. It requires
  coherent project compatibility, an `[Unreleased]` changelog, development CFF
  metadata, valid config, no tracked secret env files, and valid migration
  metadata.
- Strict preflight mode runs manually before Registrator. It requires a stable
  `X.Y.Z` version, the exact current merged `main` SHA, matching Project,
  changelog, and CFF release metadata, and an empty retained `[Unreleased]`
  section. It also runs hermetic tests, PostgreSQL 17 integration, docs/link
  checks, the one-sample benchmark smoke, and an image build.
- Post-tag mode is verification after registration. Only an exact stable
  `vX.Y.Z` tag receives release behavior; prerelease, build, malformed, and
  unrelated tags are not treated as releases.

The live Tiingo canary is not part of any of these gates. Its scheduled/manual
result is advisory and may be affected by credentials, quota, upstream status,
or symbol availability. Performance timing, allocation, and RSS measurements
are also report-only; benchmark correctness, cleanup, bounds, and timeout
checks remain enforceable.

### Release stop conditions

Do not prepare or register a package release until maintainers have resolved
the permanent package-name/repository-URL decision against current Julia
General AutoMerge guidance. Immediately before release, also recheck General
by package name and UUID, remote tags, and GitHub Releases. Never reuse a
version found in any of those locations. Verify the Registrator App and the
write-enabled `DOCUMENTER_KEY` before creating the release commit.

The current repository state remains development metadata under
`[Unreleased]`; it is not authorization to register or tag a release.

### Preflight to registration sequence

1. Create a `release-x.y.z` branch only after the stop conditions are resolved.
2. Set the selected stable version in `Project.toml`. Move release changes from
   `[Unreleased]` into a dated changelog section, advance compare links, and set
   the same `version` and ISO `date-released` in `CITATION.cff`. Keep a new,
   empty `[Unreleased]` section. Keep general documentation version-neutral.
3. Run the development checks, PostgreSQL 17 migration integration, docs,
   links, benchmark smoke, and image build in the release PR. Merge the exact
   release commit into `main` and wait for required CI to pass.
4. Set `RELEASE_VERSION` to the selected `X.Y.Z` and `RELEASE_REF` to the full
   lowercase 40-character SHA at the current tip of `origin/main`. Dispatch
   strict preflight on that same commit:

   ```bash
   gh workflow run release-preflight.yml --ref main \
     -f release_version="$RELEASE_VERSION" \
     -f release_ref="$RELEASE_REF"
   ```

5. Confirm every preflight job passed and its verified SHA equals
   `RELEASE_REF`. Any failure blocks registration. The preflight intentionally
   contains no live canary and requires no Tiingo secret.
6. Only then invoke Registrator on that exact merged commit:

   ```bash
   gh api --method POST \
     "repos/Quansift/Tiingo.jl/commits/$RELEASE_REF/comments" \
     -f body='@JuliaRegistrator register'
   ```

7. Review the generated General Registry pull request and wait for it to merge.
   If a correction is required, make a new commit and repeat preflight and
   Registrator; never move or overwrite an accepted version.
8. After General merges, allow TagBot to create the Git tag and GitHub Release.
   Do not create a competing tag before registration. The required order is
   **preflight → Registrator → General → TagBot**.
9. Treat tag CI as post-registration verification. Verify the General entry
   and `Pkg.add`, exact tag and GitHub Release, stable Documenter site, and GHCR
   version/SHA tags and digest. A later advisory canary result cannot change or
   invalidate the package release.
