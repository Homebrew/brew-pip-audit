# typed: strict
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "uri"

# Captured subprocess output and file reads are tagged with the default external
# encoding, which is US-ASCII when the runner has no UTF-8 locale.
Encoding.default_external = Encoding::UTF_8

OUT = "#{__dir__}/site/formula-requirements.json".freeze
PYTHON_SDIST_SUFFIXES = [".tar.gz", ".tar.bz2", ".zip"].freeze

stdout, stderr, status = Open3.capture3(
  "brew", "formula-python-resources", "--all", "--tap=homebrew/core"
)
abort stderr unless status.success?

collected_requirements = JSON.parse(stdout).filter_map do |formula|
  next if formula.fetch("deprecated") || formula.fetch("disabled")

  name = formula.fetch("name")
  puts name
  requirements = formula.fetch("resources").map do |resource|
    url = resource.fetch("url")
    filename = File.basename(URI.parse(url).path)
    version = if filename.end_with?(".whl")
      wheel_version = filename.delete_suffix(".whl").split("-", 3)[1]
      abort "Unexpected PyPI wheel filename: #{filename}" unless wheel_version

      wheel_version
    else
      suffix = PYTHON_SDIST_SUFFIXES.find { |candidate| filename.end_with?(candidate) }
      abort "Unexpected PyPI resource filename: #{filename}" unless suffix

      filename.delete_suffix(suffix).rpartition("-").last
    end
    abort "Could not determine a PyPI version from #{url}" if version.empty?

    "#{resource.fetch("name")}==#{version}"
  end
  [name, requirements]
end

FileUtils.mkdir_p(File.dirname(OUT))
File.write(OUT, JSON.pretty_generate(collected_requirements.to_h))
