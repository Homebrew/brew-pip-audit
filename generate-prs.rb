require "formula"
require "utils/pypi"


SKIP_FORMULA = []
# TODO: remove once we're confident this works
ONLY_FORMULA = ["grokmirror"]

for path in Dir.entries("audits")
  if !path.end_with?("-requirements.audit.json")
    next
  end
  formula = Formula[path.delete_suffix("-requirements.audit.json")]
  if SKIP_FORMULA.include?(formula.name) || !ONLY_FORMULA.include?(formula.name)
    puts "Skipping #{formula.name}"
    next
  end

  puts "Updating resources for #{formula.name}"
  PyPI.update_python_resources!(formula,
                                ignore_non_pypi_packages: true)

  args = OpenStruct.new(force?: false, quiet?: false)
  GitHub.check_for_duplicate_pull_requests(formula.name, formula.tap.remote_repo,
                                           state: "open",
                                           file: formula.path.relative_path_from(formula.tap.path).to_s
                                           args: args)

  # TODO: consider re-running pip-audit to verify at least one vuln was fixed.
  GitHub.create_bump_pr({
    sourcefile_path:  formula.path,
    branch_name:      "bump-python-resources-#{formula.name}",
    commit_message:   "#{formula.name}: bump python resources",
    tap:              formula.tap,
    pr_message:       "Created by https://github.com/Homebrew/brew-pip-audit",
  })
end
