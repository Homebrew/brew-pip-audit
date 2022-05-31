# brew-pip-audit: Bulk auditing Python dependencies in Homebrew with pip-audit

[Homebrew](https://brew.sh/) is a popular package manager for macOS. Many of the projects it packages are written in Python. In order to ensure reproducible builds, Homebrew precisely pins the version of each Python package a Homebrew formula depends on.

[`pip-audit`](https://pypi.org/project/pip-audit/) is a tool for checking a Python project's dependencies against vulnerability databases in order to determine if there are any known vulnerabilities.

This project takes all of the Python packages depended on by Homebrew formulas and runs them through `pip-audit`.

## The repo

The following things can be found in this repository:

- `formula2requirements.rb`: Extracts the Python dependencies from Homebrew and writes them out in the `requirements.txt` format.
- `pip-audit-bulk`: Runs `pip-audit` over a directory of `requirements.txt` files.
- `requirements/`: The extracted `requirements.txt` file for each Homebrew formula.
- `audits/`: The result of `pip-audit` for each Homebrew formula. There will only be a file present if vulnerabilities were found.

`requirements/` and `audits/` are automatically refreshed on a daily basis by Github Actions.

## Contributing

The best way to contribute is to take Homebrew formulas with known vulnerabilities (i.e. ones in `audits/`) and get them fixed. Sometimes this means upgrading the pinned versions in Homebrew, other times this may mean contributing to the project's upstream to bump the version.
