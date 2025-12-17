require "json"
require "formula"
require "ostruct"
require "utils/ast"
require "utils/curl"
require "utils/output"
require "utils/pypi"

# Don't buffer stdout; with buffering, some of our stdout/stderr
# logging below gets interleaved incorrectly.
$stdout.sync = true

AUDIT_JSON_URL = "https://homebrew.github.io/brew-pip-audit/formula-audits.json"

# TODO: Support grabbing these from the environment.
ONLY_FORMULA = []
SKIP_FORMULA = [
  # Has a weird PyInstaller-based install that `pip` can't handle
  # https://github.com/Homebrew/homebrew-core/blob/5eb7ab4f78c012514871011fd1ab80fb0911809f/Formula/gyb.rb#L151-L160
  "gyb",
  # setup.py requires another package to be pre-installed. Should really use pyproject.toml.
  # https://github.com/OfflineIMAP/offlineimap3/pull/157
  "offlineimap",
  "zim",
  # No setup.py.
  "recon-ng",
  "gnuradio",
  # Installable packages are in a sub-directory
  "azure-cli",
  # Hopelessly complicated build
  "pytorch",
  # ansible-lint depends on ansible, which can be handled when ansible got updated
  # and there is also complexity if the vulnerability is in ansible-core, which would cause
  # ansible-core version discrepancy between ansible and ansible-lint
  "ansible-lint",
  # Can't determine metadata from git repo. We'd ideally use a pure-Python
  # wheel from PyPI but my initial attempt to support that in Homebrew
  # was an exercise in frustration.
  "icloudpd",
]

PR_LIMIT = ENV.fetch("HOMEBREW_AUTO_PR_LIMIT", 25).to_i

# NOTE: The dry-run default here is the opposite of the workflow_dispatch
# default, since the latter's default makes more sense for manually
# triggered runs.
DRY_RUN = ENV.fetch("HOMEBREW_AUTO_PR_DRY_RUN", "false") == "true"

NO_FORK = ENV.fetch("HOMEBREW_AUTO_PR_NO_FORK", "false") == "true"

SUMMARY_PATH = ENV.fetch("GITHUB_STEP_SUMMARY", nil)

Utils::Output.ohai "generate-prs running with DRY_RUN=#{DRY_RUN}, PR_LIMIT=#{PR_LIMIT}, SUMMARY_PATH=#{SUMMARY_PATH}"

PR_MESSAGE = <<~MSG
  Created by `brew-pip-audit`.

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

# Helper: Insert or bump the `revision` stanza so that it appears
# after any `license` stanza but before any `head` stanza.
def manually_bump_revision(formula, next_revision)
  formula_ast = Utils::AST::FormulaAST.new(formula.path.read)
  tree_rewriter = formula_ast.send(:tree_rewriter)

  # See if there's already a "revision" stanza
  existing_revision = formula_ast.stanza(:revision)

  if existing_revision
    formula_ast.replace_stanza(:revision, next_revision)
  else
    license_node = formula_ast.stanza(:license)
    head_node    = formula_ast.stanza(:head)

    if license_node
      insert_after_node(tree_rewriter: tree_rewriter,
                        node: license_node,
                        name: :revision,
                        value: next_revision)
    elsif head_node
      insert_before_node(tree_rewriter: tree_rewriter,
                         node: head_node,
                         name: :revision,
                         value: next_revision)
    else
      # Fallback if neither license nor head stanzas are found
      formula_ast.add_stanza(:revision, next_revision)
    end
  end

  formula.path.atomic_write(formula_ast.process)
end

# Helper to insert a stanza AFTER an existing node
def insert_after_node(tree_rewriter:, node:, name:, value:)
  node_expr = node.location.expression
  stanza_str = "\n  #{name} #{value}"
  tree_rewriter.insert_after(node_expr, stanza_str)
end

# Helper to insert a stanza BEFORE an existing node
def insert_before_node(tree_rewriter:, node:, name:, value:)
  node_expr = node.location.expression
  stanza_str = "  #{name} #{value}\n"
  tree_rewriter.insert_before(node_expr, stanza_str)
end

result = ::Utils::Curl.curl_output("--fail", "--silent", "--location", AUDIT_JSON_URL)
result.assert_success!

audit_json = JSON.parse(result.stdout)

audit_json["vulnerable"].each do |formula_name, audit|
  vulnerable_deps = audit.map { |dep| dep["package"]["name"] }

  Utils::Output.ohai "#{formula_name}: attempting to patch deps: #{vulnerable_deps.join(", ")}"

  formula = Formula[formula_name]
  if SKIP_FORMULA.include?(formula.name) || (!ONLY_FORMULA.empty? && !ONLY_FORMULA.include?(formula.name))
    Utils::Output.ohai "#{formula.name}: skipping"
    results.push({formula: formula_name, updated: false, reason: "Skipped because of SKIP_FORMULA/ONLY_FORMULA"})
    next
  end

  if formula.deprecated? || formula.disabled?
    Utils::Output.opoo "#{formula.name}: skipping deprecated/disabled formula"
    results.push({formula: formula_name, updated: false, reason: "Skipped because deprecated or disabled"})
    next
  end

  old_resource_urls = formula.resources.map do |r|
    r.url if vulnerable_deps.include?(PyPI.normalize_python_package r.name) && r.url =~ /\Ahttps?:\/\/files\.pythonhosted\.org\//
  end.compact

  Utils::Output.ohai "#{formula_name}: vulnerable dist URLs: #{old_resource_urls.join(", ")}"

  # HACK: Clean up the last step's update.
  formula.path.parent.cd do
    `git reset --hard HEAD`
  end

  # Bump the formula's revision as well; adapted from `brew bump-revision`.
  manually_bump_revision(formula, formula.revision + 1)

  Utils::Output.ohai "#{formula.name}: updating Python resources"
  # TODO: Updating Python resources automatically can fail for myriad reasons;
  # we should try and handle some of them.
  begin
    PyPI.update_python_resources!(formula, verbose: true)
  rescue SystemExit => e
    Utils::Output.opoo "#{formula_name} update_python_resources! failed: suppressing the previous exit and skipping"
    results.push({formula: formula_name, updated: false, reason: "`update_python_resources!` failed: #{e}"})
    next
  end

  # Re-load the formula to have the newly updated Python resources take effect.
  Formulary.clear_cache
  formula = Formula[formula.name]

  new_resource_urls = formula.resources.map do |r|
    r.url if vulnerable_deps.include?(PyPI.normalize_python_package r.name) && r.url =~ /\Ahttps?:\/\/files\.pythonhosted\.org\//
  end.compact

  Utils::Output.ohai "#{formula_name}: patched dist URLs: #{new_resource_urls.join(", ")}"

  # If we haven't changed any of the relevant resource URLs, then our resource
  # update only updated non-vulnerable dependencies.
  # We skip the pull request in this case, since we're not in the business
  # of updating non-vulnerable dependencies.
  vulns_patched = old_resource_urls - new_resource_urls
  if vulns_patched.empty?
    Utils::Output.opoo "#{formula_name}: no vulnerabilities patched; skipping this PR"
    results.push({formula: formula_name, updated: false, reason: "No vulnerabilities patched. Vulnerable dependencies: #{old_resource_urls.map { |s| "`#{s}`" }.join(", ") }"})
    next
  else
    Utils::Output.ohai "#{formula_name}: patched: #{vulns_patched.join(", ")}"
  end

  if DRY_RUN
    Utils::Output.ohai "#{formula_name}: not issuing PR due to dry run"
    results.push({formula: formula_name, updated: false, reason: "Dry run"})
    next
  end

  begin
    GitHub.check_for_duplicate_pull_requests(formula.name, formula.tap.remote_repository,
                                            state: "open",
                                            file: formula.path.relative_path_from(formula.tap.path).to_s,
                                            quiet: false,
                                            strict: true)
  rescue SystemExit => e
    Utils::Output.opoo "#{formula_name} PR dupe check failed: suppressing the previous exit and skipping"
    results.push({formula: formula_name, updated: false, reason: "Existing PR for this formula"})
    next
  end

  next if formula.path.parent.cd do
    # HACK: `create_bump_pr` fails if the path is unchanged, which sometimes
    # happens for reasons I haven't debugged yet.
    `git diff --quiet -- #{formula.path}`
    $?.success?
  end

  commit_message = "#{formula.name}: bump python resources"
  old_contents = File.read(formula.path)

  info = {
    commits:     [
      {
        sourcefile_path:  formula.path,
        commit_message:,
        old_contents:,
      }
    ],
    branch_name: "brew-pip-audit-#{formula.name}-#{Time.now.to_i}",
    pr_message:  PR_MESSAGE % {old_urls: old_resource_urls.join("\n"), new_urls: vulns_patched.join("\n")},
    tap:         formula.tap,
    pr_title:    commit_message
  }
  GitHub.create_bump_pr(info, args: OpenStruct.new(:no_fork? => NO_FORK))
  prs_sent += 1
  results.push({formula: formula_name, updated: true, reason: ""})
  if prs_sent == PR_LIMIT
    Utils::Output.ohai "generate-prs: Reached maximum limit of #{PR_LIMIT} PRs sent per run"
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
