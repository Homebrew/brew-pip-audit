require "formula"
require "utils/pypi"


SKIP_FORMULA = []

for path in Dir.entries("audits")
  if !path.end_with?("-requirements.audit.json")
    next
  end
  formula = Formula[path.delete_suffix("-requirements.audit.json")]
  if SKIP_FORMULA.include?(formula.name)
    ohai "Skipping #{formula.name}"
    next
  end

  ohai "Updating resources for #{formula.name}"
  # TODO: Updating Python resources automatically can fail for myriad reasons;
  # we should try and handle some of them.
  begin
    PyPI.update_python_resources!(formula,
                                  ignore_non_pypi_packages: true)
  rescue SystemExit => e
    opoo "generate-prs: suppressing the previous exit"
    next
  end


  begin
    args = OpenStruct.new(force?: false, quiet?: false)
    GitHub.check_for_duplicate_pull_requests(formula.name, formula.tap.remote_repo,
                                            state: "open",
                                            file: formula.path.relative_path_from(formula.tap.path).to_s,
                                            args: args)
  rescue SystemExit => e
    opoo "generate-prs: suppressing the previous exit"
    next
  end

  formula.path.parent.cd do
    # HACK: `create_bump_pr` fails if the path is unchanged, which sometimes
    # happens for reasons I haven't debugged yet.
    `git diff --exit-code #{formula.path}`
    next if $?.success?
  end

  # TODO: consider re-running pip-audit to verify at least one vuln was fixed.
  info = {
    sourcefile_path:  formula.path,
    branch_name:      "bump-python-resources-#{formula.name}",
    commit_message:   "#{formula.name}: bump python resources",
    tap:              formula.tap,
    pr_message:       "Created by https://github.com/Homebrew/brew-pip-audit",
  }
  GitHub.create_bump_pr(info, args: OpenStruct.new)
end
