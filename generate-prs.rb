require "json"
require "formula"
require "utils/pypi"


ONLY_FORMULA = []
SKIP_FORMULA = []
PR_LIMIT = 5

PR_MESSAGE = <<~MSG
  Created by [`brew-pip-audit`](https://github.com/Homebrew/brew-pip-audit).

  On errors/problems, please ping `@woodruffw` or `@alex`.
MSG

prs_sent = 0
for path in Dir.entries("audits").sort
  if !path.end_with?("-requirements.audit.json")
    next
  end

  vulnerable_deps = do
    audit = JSON.parse File.read(path)

    audit.map { |dep| dep["name"] }
  end

  formula = Formula[path.delete_suffix("-requirements.audit.json")]
  if SKIP_FORMULA.include?(formula.name) || (!ONLY_FORMULA.empty? && !ONLY_FORMULA.include?(formula.name))
    ohai "Skipping #{formula.name}"
    next
  end

  if formula.deprecated? || formula.disabled?
    opoo "Skipping deprecated/disabled formula: #{formula.name}"
    next
  end

  old_resource_urls = formula.resources.map do |r|
    r.url if vulnerable_deps.include?(PyPI.normalize_python_package r.name) && r.url =~ /files\.pythonhosted\.org/
  end.compact

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

  # Re-load the formula to have the newly updated Python resources take effect.
  Formulary.clear_cache
  formula = Formula[formula.name]

  new_resource_urls = formula.resources.map do |r|
    r.url if vulnerable_deps.include?(PyPI.normalize_python_package r.name) && r.url =~ /files\.pythonhosted\.org/
  end.compact

  # If we haven't changed any of the relevant resource URLs, then our resource
  # update only updated non-vulnerable dependencies.
  # We skip the pull request in this case, since we're not in the business
  # of updating non-vulnerable dependencies.
  if (old_resource_urls - new_resource_urls).empty?
    opoo "no vulnerabilities patched; skipping this PR"
    next
  end

  if ENV["AUTO_PR_DRY_RUN"] == "true"
    ohai "not issuing PR due to dry run"
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
