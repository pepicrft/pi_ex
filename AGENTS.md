# Agent Guidelines

Guidelines for AI agents working on this codebase.

## Testing

### No global state modification

**All tests must use `async: true`** (the default). To achieve this:

- **Never** use `Application.put_env/3` or `Application.delete_env/2` in tests
- **Never** modify process dictionaries or other global state
- Design modules to accept options/configuration as function arguments
- Pass test-specific values (like `tmp_dir`) through options

**Bad:**
```elixir
# ❌ Modifies global state, requires async: false
test "installs to directory", %{tmp_dir: tmp_dir} do
  Application.put_env(:pi_ex, :cache_dir, tmp_dir)
  on_exit(fn -> Application.delete_env(:pi_ex, :cache_dir) end)
  
  Installer.install()
end
```

**Good:**
```elixir
# ✅ Passes config through options, can use async: true
test "installs to directory", %{tmp_dir: tmp_dir} do
  Installer.install(cache_dir: tmp_dir)
end
```

### Module design for testability

When designing modules, prefer explicit arguments over implicit config:

```elixir
# ✅ Good: accepts options, falls back to config
def install(opts \\ []) do
  cache_dir = Keyword.get(opts, :cache_dir, Config.cache_dir())
  # ...
end

# ❌ Bad: only reads from global config
def install do
  cache_dir = Config.cache_dir()
  # ...
end
```

This pattern:
- Enables `async: true` tests (faster, parallel execution)
- Makes dependencies explicit
- Improves reusability and composability

## Code Style

- Use `@enforce_keys` for required struct fields
- Add typespecs to public functions
- Use behaviours for extensibility points (see `PiEx.Tool`)
- Follow XDG Base Directory Specification for cache/config paths
