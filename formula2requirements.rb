# homebrew-core: 23f83804493c17380cb03e8b2c15088a6acf51d5

require "fileutils"
require "uri"

require "formulary"
require "formula"

OUT = "#{__dir__}/requirements"

# Completely blow away the existing requirements dir, and then re-create it:
# this clears out any requirements files that have been orphaned by upstream
# formula deletion.
FileUtils.rm_rf OUT
FileUtils.mkdir_p OUT

Formula.all.each do |f|
  requirement_file = "#{OUT}/#{f.name}-requirements.txt"

  # Look for formulae that have PyPI resources; skip those that don't.
  python_resources = f.resources.select { |r| r.url =~ /files\.pythonhosted\.org/ }
  if python_resources.empty?
    FileUtils.rm_f requirement_file
    next
  end

  # Skip deprecated and disabled formulae but not before removing any
  # previously generated requirements, if present.
  if f.deprecated? || f.disabled?
    FileUtils.rm_f requirement_file
    next
  end


  puts f.name
  File.open requirement_file, "w" do |io|
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
               else
                 abort "barf: unexpected suffix in #{path}"
               end

      version = path.rpartition("-").last.delete_suffix suffix

      io.puts "#{pr.name}==#{version} --hash=sha256:#{pr.checksum.hexdigest}"
    end
  end
end
