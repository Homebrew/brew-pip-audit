# typed: strict
# frozen_string_literal: true

require "json"
require "English"
require "open3"
require "tempfile"

# Captured subprocess output and file reads are tagged with the default external
# encoding, which is US-ASCII when the runner has no UTF-8 locale.
Encoding.default_external = Encoding::UTF_8

# Don't buffer stdout; otherwise command and controller logs can interleave.
$stdout.sync = true

# Orchestrates one supported Homebrew command invocation per vulnerable formula.
module BrewPipAudit
  AUDIT_JSON_URL = "https://homebrew.github.io/brew-pip-audit/formula-audits.json"

  # TODO: Support grabbing these from the environment.
  ONLY_FORMULA = [].freeze
  SKIP_FORMULA = [
    # Has a weird PyInstaller-based install that `pip` can't handle.
    "gyb",
    # setup.py requires another package to be pre-installed.
    "offlineimap",
    "zim",
    # No setup.py.
    "recon-ng",
    "gnuradio",
    # Installable packages are in a sub-directory.
    "azure-cli",
    # Hopelessly complicated build.
    "pytorch",
    # ansible-lint depends on ansible and requires coordinated updates.
    "ansible-lint",
    # Metadata cannot be determined from the git repository.
    "icloudpd",
  ].freeze

  class << self
    def run
      pr_limit = ENV.fetch("HOMEBREW_AUTO_PR_LIMIT", 25).to_i
      dry_run = ENV.fetch("HOMEBREW_AUTO_PR_DRY_RUN", "false") == "true"
      no_fork = ENV.fetch("HOMEBREW_AUTO_PR_NO_FORK", "false") == "true"
      quick_run = ENV.fetch("HOMEBREW_AUTO_PR_QUICK_RUN", "false") == "true"
      summary_path = ENV.fetch("GITHUB_STEP_SUMMARY", nil)

      ohai "generate-prs running with DRY_RUN=#{dry_run}, PR_LIMIT=#{pr_limit}, " \
           "QUICK_RUN=#{quick_run}, SUMMARY_PATH=#{summary_path}"

      prs_attempted = 0
      results = []

      fetch_audit_json.fetch("vulnerable").each_with_index do |(formula_name, audit), index|
        if quick_run && index >= 10
          ohai "generate-prs: quick run enabled, skipping remaining formulae"
          break
        end

        vulnerable_dependencies = audit.map { |dependency| dependency.fetch("package").fetch("name") }
        ohai "#{formula_name}: attempting to patch deps: #{vulnerable_dependencies.join(", ")}"

        selected = ONLY_FORMULA.empty? || ONLY_FORMULA.include?(formula_name)
        if SKIP_FORMULA.include?(formula_name) || !selected
          ohai "#{formula_name}: skipping"
          results << {
            formula: formula_name,
            updated: false,
            reason:  "Skipped because of SKIP_FORMULA/ONLY_FORMULA",
          }
          next
        end

        result = run_bump(formula_name, vulnerable_dependencies, dry_run:, no_fork:)
        attempted = result.fetch("attempted")
        updated = result.fetch("updated")
        reason = result.fetch("reason")
        prs_attempted += 1 if attempted

        if updated
          ohai "#{formula_name}: pull request created: #{reason}"
        else
          opoo "#{formula_name}: #{reason}"
        end
        results << { formula: formula_name, updated:, reason: }

        if prs_attempted == pr_limit
          ohai "generate-prs: reached maximum limit of #{pr_limit} pull requests"
          break
        end
      end

      write_summary(summary_path, results) if summary_path
    end

    private

    def ohai(message)
      puts "==> #{message}"
    end

    def opoo(message)
      warn "Warning: #{message}"
    end

    def fetch_audit_json
      stdout, stderr, status = Open3.capture3(
        "curl",
        "--fail",
        "--silent",
        "--show-error",
        "--location",
        AUDIT_JSON_URL,
      )
      abort stderr unless status.success?

      JSON.parse(stdout)
    end

    def run_bump(formula_name, vulnerable_dependencies, dry_run:, no_fork:)
      Tempfile.create(["brew-pip-audit-", ".json"]) do |output|
        output.close
        command = [
          "brew", "bump-python-resources-pr",
          "--packages=#{vulnerable_dependencies.join(",")}",
          "--branch=brew-pip-audit-#{formula_name}-#{Time.now.to_i}",
          "--message=Created by `brew-pip-audit`.",
          "--output=#{output.path}"
        ]
        command << "--dry-run" if dry_run
        command << "--no-fork" if no_fork
        command << formula_name

        success = system(*command)
        status = $CHILD_STATUS

        if success && File.size?(output.path)
          JSON.parse(File.read(output.path))
        else
          reason = if status
            "brew bump-python-resources-pr failed with status #{status.exitstatus}"
          else
            "brew bump-python-resources-pr failed to execute"
          end
          {
            "attempted" => false,
            "updated"   => false,
            "reason"    => reason,
          }
        end
      end
    end

    def markdown_cell(value)
      value.to_s.gsub(/[\\|]/) { |char| "\\#{char}" }.gsub("\n", "<br>")
    end

    def write_summary(summary_path, results)
      File.open(summary_path, "a") do |file|
        file.write("| Formula | Updated? | Reason |\n")
        file.write("| ------- | -------- | ------ |\n")
        results.each do |result|
          file.write("| #{markdown_cell(result[:formula])} | #{result[:updated]} | " \
                     "#{markdown_cell(result[:reason])} |\n")
        end
      end
    end
  end
end

BrewPipAudit.run
