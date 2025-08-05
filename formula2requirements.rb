# homebrew-core: 23f83804493c17380cb03e8b2c15088a6acf51d5

require "fileutils"
require "uri"
require "json"

require "formulary"
require "formula"

OUT = "#{__dir__}/site/formula-requirements.json"

collected_requirements = Hash.new { |h, k| h[k] = [] }
Formula.all.sort.each do |f|
  # Skip formulae that aren't in homebrew/core.
  next unless f.tap.name == "homebrew/core"

  # Look for formulae that have PyPI resources; skip those that don't.
  python_resources = f.resources.select { |r| URI.parse(r.url).host == "files.pythonhosted.org" }
  next if python_resources.empty?

  # Skip deprecated and disabled formulae.
  next if f.deprecated? || f.disabled?

  puts f.name
  python_resources.each do |pr|
    # Each pythonhosted resource URL looks something like this:
    # https://files.pythonhosted.org/packages/PREFIX/PREFIX/LONG_BLAKE_HASH/PKGNAME-X.Y.Z.ext
    #
    # The only things we care about from the URL itself are
    # the version (X.Y.Z) and the extension (and we only care about the
    # latter so we can strip it correctly).
    path = URI::parse(pr.url).path
    suffix = if path.end_with? ".zip"
                ".zip"
              elsif path.end_with? ".tar.gz"
                ".tar.gz"
              elsif path.end_with? ".tar.bz2"
                ".tar.bz2"
              elsif path.end_with? "-py3-none-any.whl"
                "-py3-none-any.whl"
              elsif path.end_with? "-py2.py3-none-any.whl"
                "-py2.py3-none-any.whl"
              else
                abort "barf: unexpected suffix in #{path}"
              end

    version = path.rpartition("-").last.delete_suffix suffix

    collected_requirements[f.name] << "#{pr.name}==#{version}"
  end
end

File.write(OUT, JSON.pretty_generate(collected_requirements))
