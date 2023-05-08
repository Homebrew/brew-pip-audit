# brew-pip-audit: Bulk auditing Python dependencies in Homebrew with osv-scanner

[Homebrew](https://brew.sh/) is a popular package manager for macOS.
Many of the projects it packages are written in Python. In order to ensure
reproducible builds, Homebrew precisely pins the version of each Python package
a Homebrew formula depends on.

[`osv-scanner`](https://google.github.io/osv-scanner/) is a tool for checking
a project's dependencies against vulnerability databases in order to determine
if there are any known vulnerabilities.

This project takes all of the Python packages depended on by Homebrew formulas
and runs them through `osv-scanner`. It then takes those audit results and uses
them to submit patches to Homebrew.

This project previously used
[`pip-audit`](https://pypi.org/project/pip-audit/), instead of `osv-scanner`,
hence the name.

## The repo

The following things can be found in this repository:

- `formula2requirements.rb`: Extracts the Python dependencies from Homebrew
  and writes them out in the `requirements.txt` format.
- `pip-audit-bulk`: Runs `osv-scanner` over a directory of `requirements.txt`
  files.
- `generate-prs.rb`: Automatically generates PRs against
  `Homebrew/homebrew-core` for formulae with vulnerable dependencies.
- `requirements/`: The extracted `requirements.txt` file for each Homebrew
  formula.
- `audits/`: The result of `osv-scanner` for each Homebrew formula. There will
  only be a file present if vulnerabilities were found.

`requirements/` and `audits/` are automatically refreshed on a daily basis by
Github Actions.

## Contributing

This repository is automated, but the automation isn't perfect. You can help
out by:

- Looking at the `skipped` file, and trying to figure out why a particular
  dependency's audit was skipped.
- Looking at the [incoming PRs] against `Homebrew/homebrew-core`, and helping
  debug ones that fail.
- Improving the performance of our automation (it's currently very slow).
- Looking at the [action logs] for the PR automation, and helping debug/fix
  formulae and dependencies that can't be auto-updated.

[incoming PRs]: https://github.com/Homebrew/homebrew-core/pulls?q=is%3Aopen+is%3Apr+author%3ABrewTestBot+%22bump+python+resources%22+in%3Atitle

[action logs]: https://github.com/Homebrew/brew-pip-audit/actions/workflows/auto-pr.yml
