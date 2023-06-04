require "json"
require "formula"
require "utils/ast"
require "utils/pypi"

# Don't buffer stdout; with buffering, some of our stdout/stderr
# logging below gets interleaved incorrectly.
$stdout.sync = true

# TODO: Support grabbing these from the environment.
ONLY_FORMULA = []
SKIP_FORMULA = []

PR_LIMIT = ENV.fetch("HOMEBREW_AUTO_PR_LIMIT", 25).to_i

# NOTE: The dry-run default here is the opposite of the workflow_dispatch
# default, since the latter's default makes more sense for manually
# triggered runs.
DRY_RUN = ENV.fetch("HOMEBREW_AUTO_PR_DRY_RUN", "false") == "true"

SUMMARY_PATH = ENV.fetch("GITHUB_STEP_SUMMARY", nil)

ohai "generate-prs running with DRY_RUN=#{DRY_RUN}, PR_LIMIT=#{PR_LIMIT}, SUMMARY_PATH=#{SUMMARY_PATH}"

PR_MESSAGE = <<~MSG
  Created by [`brew-pip-audit`](https://github.com/Homebrew/brew-pip-audit).

  The following resources have known vulnerabilities:

  ```console
  %{old_urls}
  ```

  Of those, the following were patched:

  ```console
  %{new_urls}
  ```
MSG

prs_sent = 0
results = []

for path in Dir.entries("audits").sort
  if !path.end_with?("-requirements.audit.json")
    next
  end

  formula_name = path.delete_suffix("-requirements.audit.json")
  vulnerable_deps = begin
    audit = JSON.parse File.read("audits/#{path}")

    audit.map { |dep| dep["package"]["name"] }
  end

  ohai "#{formula_name}: attempting to patch deps: #{vulnerable_deps.join(", ")}"

  formula = Formula[path.delete_suffix("-requirements.audit.json")]
  if SKIP_FORMULA.include?(formula.name) || (!ONLY_FORMULA.empty? && !ONLY_FORMULA.include?(formula.name))
    ohai "#{formula.name}: skipping"
    results.push({formula: formula_name, updated: false, reason: "Skipped because of SKIP_FORMULA/ONLY_FORMULA"})
    next
  end

  if formula.deprecated? || formula.disabled?
    opoo "#{formula.name}: skipping deprecated/disabled formula"
    results.push({formula: formula_name, updated: false, reason: "Skipped because deprecated or disabled"})
    next
  end

  old_resource_urls = formula.resources.map do |r|
    r.url if vulnerable_deps.include?(PyPI.normalize_python_package r.name) && r.url =~ /files\.pythonhosted\.org/
  end.compact

  ohai "#{formula_name}: vulnerable dist URLs: #{old_resource_urls.join(", ")}"

  # HACK: Clean up the last step's update.
  formula.path.parent.cd do
    `git reset --hard HEAD`
  end

  # Bump the formula's revision as well; adapted from `brew bump-revision`.
  current_revision = formula.revision
  next_revision = current_revision + 1
  ohai "#{formula_name}: marking as revision #{next_revision}"

  formula_ast = Utils::AST::FormulaAST.new(formula.path.read)
  if current_revision.zero?
    formula_ast.add_stanza(:revision, next_revision)
  else
    formula_ast.replace_stanza(:revision, next_revision)
  end
  formula_ast.remove_stanza(:bottle)
  formula.path.atomic_write(formula_ast.process)

  ohai "#{formula.name}: updating Python resources"
  # TODO: Updating Python resources automatically can fail for myriad reasons;
  # we should try and handle some of them.
  begin
    PyPI.update_python_resources!(formula,
                                  ignore_non_pypi_packages: true)
  rescue SystemExit => e
    opoo "#{formula_name} update_python_resources! failed: suppressing the previous exit and skipping"
    results.push({formula: formula_name, updated: false, reason: "`update_python_resources!` failed"})
    next
  end

  # Re-load the formula to have the newly updated Python resources take effect.
  Formulary.clear_cache
  formula = Formula[formula.name]

  new_resource_urls = formula.resources.map do |r|
    r.url if vulnerable_deps.include?(PyPI.normalize_python_package r.name) && r.url =~ /files\.pythonhosted\.org/
  end.compact

  ohai "#{formula_name}: patched dist URLs: #{new_resource_urls.join(", ")}"

  # If we haven't changed any of the relevant resource URLs, then our resource
  # update only updated non-vulnerable dependencies.
  # We skip the pull request in this case, since we're not in the business
  # of updating non-vulnerable dependencies.
  vulns_patched = old_resource_urls - new_resource_urls
  if vulns_patched.empty?
    opoo "#{formula_name}: no vulnerabilities patched; skipping this PR"
    results.push({formula: formula_name, updated: false, reason: "No vulnerabilities patched. Vulnerable dependencies: #{old_resource_urls.map { |s| "`#{s}`" }.join(", ") }"})
    next
  else
    ohai "#{formula_name}: patched: #{vulns_patched.join(", ")}"
  end

  if DRY_RUN
    ohai "#{formula_name}: not issuing PR due to dry run"
    results.push({formula: formula_name, updated: false, reason: "Dry run"})
    next
  end

  begin
    args = OpenStruct.new(force?: false, quiet?: false)
    GitHub.check_for_duplicate_pull_requests(formula.name, formula.tap.remote_repo,
                                            state: "open",
                                            file: formula.path.relative_path_from(formula.tap.path).to_s,
                                            args: args)
  rescue SystemExit => e
    opoo "#{formula_name} PR dupe check failed: suppressing the previous exit and skipping"
    results.push({formula: formula_name, updated: false, reason: "Existing PR for this formula"})
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
    pr_message:       PR_MESSAGE % {old_urls: old_resource_urls.join("\n"), new_urls: vulns_patched.join("\n")},
  }
  GitHub.create_bump_pr(info, args: OpenStruct.new)
  prs_sent += 1
  results.push({formula: formula_name, updated: true, reason: ""})
  if prs_sent == PR_LIMIT
    ohai "generate-prs: Reached maximum limit of #{PR_LIMIT} PRs sent per run"
    break
  end
end

if SUMMARY_PATH
  File.open(SUMMARY_PATH, "a") do |f|
    f.write("| Formula | Updated? | Reason |\n")
    f.write("| ------- | -------- | ------ |\n")
    results.each do |r|
      f.write("| #{r[:formula]} | #{r[:updated]} | #{r[:reason]} |\n")
    end
  end
end
