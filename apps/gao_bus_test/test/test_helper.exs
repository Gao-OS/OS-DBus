# Ensure test support modules are loaded (needed when running from umbrella root)
for file <- Path.wildcard(Path.join(__DIR__, "support/*.ex")) do
  Code.require_file(file)
end

ExUnit.start(exclude: [:interop, :e2e])
