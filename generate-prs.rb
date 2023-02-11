require "formula"
require "utils/pypi"


SKIP_FORMULA = []
PR_LIMIT = 25

PR_MESSAGE = <<~MSG
  Created by [`brew-pip-audit`](https://github.com/Homebrew/brew-pip-audit).

  On errors/problems, please ping `@woodruffw` or `@alex`.
MSG

prs_sent = 0
for path in Dir.entries("audits").sort
  if !path.end_with?("-requirements.audit.json")
    next
  end
  formula = Formula[path.delete_suffix("-requirements.audit.json")]
  if SKIP_FORMULA.include?(formula.name)
    ohai "Skipping #{formula.name}"
    next
  end

  if formula.deprecated? || formula.disabled?
    opoo "Skipping deprecated/disabled formula: #{formula.name}"
    next
  end

  # HACK: Clean up the last step's update.
  formula.path.parent.cd do
    `git reset --hard HEAD`
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

  next if formula.path.parent.cd do
    # HACK: `create_bump_pr` fails if the path is unchanged, which sometimes
    # happens for reasons I haven't debugged yet.
    `git diff --quiet -- #{formula.path}`
    $?.success?
  end

  # TODO: consider re-running pip-audit to verify at least one vuln was fixed.
  info = {
    sourcefile_path:  formula.path,
    branch_name:      "brew-pip-audit-#{formula.name}-#{Time.now.to_i}",
    commit_message:   "#{formula.name}: bump python resources",
    tap:              formula.tap,
    pr_message:       PR_MESSAGE,
  }
  GitHub.create_bump_pr(info, args: OpenStruct.new)
  prs_sent += 1
  if prs_sent == PR_LIMIT
    ohai "generate-prs: Reached maximum limit of #{PR_LIMIT} PRs sent per run"
    return
  end
end
