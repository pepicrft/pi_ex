defmodule PiEx.Installer do
  @moduledoc """
  Handles installation and bundling of the pi coding agent SDK.

  The installer:
  1. Downloads the pi SDK from npm
  2. Bundles it with Node.js API shims that delegate to Elixir via Beam.callSync()
  3. Produces a single JavaScript bundle that runs in QuickBEAM
  """

  require Logger

  alias PiEx.Config

  @doc """
  Ensures the pi SDK is installed and bundled.
  """
  @spec ensure_installed!() :: :ok
  def ensure_installed! do
    if Config.installed?() do
      :ok
    else
      case install() do
        :ok -> :ok
        {:error, reason} -> raise "Failed to install pi SDK: #{inspect(reason)}"
      end
    end
  end

  @doc """
  Checks if the SDK bundle exists.
  """
  @spec installed?() :: boolean()
  defdelegate installed?, to: Config

  @doc """
  Installs and bundles the pi SDK.
  """
  @spec install() :: :ok | {:error, term()}
  def install, do: install(Config.version())

  @doc """
  Installs a specific version of the pi SDK.
  """
  @spec install(String.t()) :: :ok | {:error, term()}
  def install(version) do
    package_dir = Path.join(Config.cache_dir(), "pi-coding-agent-#{version}")
    bundle_path = Path.join(package_dir, "bridge.bundle.js")

    if File.exists?(bundle_path) do
      Logger.debug("Pi SDK #{version} already installed")
      :ok
    else
      do_install(version, package_dir)
    end
  end

  defp do_install(version, package_dir) do
    Logger.info("Installing pi coding agent #{version}...")

    File.mkdir_p!(package_dir)

    with :ok <- copy_bridge_file(package_dir),
         :ok <- create_package_json(package_dir, version),
         :ok <- run_npm_install(package_dir),
         :ok <- create_bundle_script(package_dir),
         :ok <- run_bundle(package_dir) do
      Logger.info("Successfully installed pi coding agent #{version}")
      :ok
    else
      {:error, reason} = error ->
        Logger.error("Failed to install pi SDK: #{inspect(reason)}")
        File.rm_rf(package_dir)
        error
    end
  end

  defp copy_bridge_file(package_dir) do
    priv_dir = :code.priv_dir(:pi_ex) |> to_string()
    bridge_src = Path.join([priv_dir, "js", "bridge.ts"])
    bridge_dest = Path.join(package_dir, "bridge.ts")

    if File.exists?(bridge_src) do
      File.cp!(bridge_src, bridge_dest)
      :ok
    else
      {:error, :bridge_file_not_found}
    end
  end

  defp create_package_json(package_dir, version) do
    package_json = %{
      "name" => "pi-ex-runtime",
      "version" => "1.0.0",
      "private" => true,
      "type" => "module",
      "dependencies" => %{
        "@mariozechner/pi-coding-agent" => version,
        "esbuild" => "^0.25.0"
      }
    }

    path = Path.join(package_dir, "package.json")
    File.write!(path, JSON.encode!(package_json))
    :ok
  end

  defp run_npm_install(package_dir) do
    cond do
      command_exists?("npm") ->
        run_command("npm", ["install", "--prefer-offline"], package_dir)

      command_exists?("pnpm") ->
        run_command("pnpm", ["install", "--shamefully-hoist"], package_dir)

      command_exists?("yarn") ->
        run_command("yarn", ["install"], package_dir)

      true ->
        {:error, :no_package_manager}
    end
  end

  defp create_bundle_script(package_dir) do
    # Shims are embedded directly in the esbuild plugin as virtual modules
    # They use Beam.callSync() which QuickBEAM provides
    script = ~S"""
    import * as esbuild from 'esbuild';

    // Virtual module shims that delegate to Elixir via Beam.callSync()
    const shims = {
      // ============ fs shim ============
      'shim:fs': `
        export function readFileSync(path, options) {
          const encoding = typeof options === 'string' ? options : options?.encoding;
          const result = Beam.callSync('fs:readFileSync', path, encoding || null);
          if (result.error) throw new Error(result.error);
          return result.data;
        }
        export function writeFileSync(path, data, options) {
          const result = Beam.callSync('fs:writeFileSync', path, data);
          if (result.error) throw new Error(result.error);
        }
        export function existsSync(path) {
          return Beam.callSync('fs:existsSync', path);
        }
        export function mkdirSync(path, options) {
          const result = Beam.callSync('fs:mkdirSync', path, options?.recursive || false);
          if (result.error) throw new Error(result.error);
        }
        export function readdirSync(path) {
          const result = Beam.callSync('fs:readdirSync', path);
          if (result.error) throw new Error(result.error);
          return result.data;
        }
        export function statSync(path) {
          const result = Beam.callSync('fs:statSync', path);
          if (result.error) throw new Error(result.error);
          return {
            isFile: () => result.data.type === 'file',
            isDirectory: () => result.data.type === 'directory',
            isSymbolicLink: () => result.data.type === 'symlink',
            size: result.data.size,
            mtime: new Date(result.data.mtime),
          };
        }
        export function lstatSync(path) { return statSync(path); }
        export function unlinkSync(path) {
          const result = Beam.callSync('fs:unlinkSync', path);
          if (result.error) throw new Error(result.error);
        }
        export function rmSync(path, options) {
          const result = Beam.callSync('fs:rmSync', path, options?.recursive || false);
          if (result.error) throw new Error(result.error);
        }
        export function realpathSync(path) {
          const result = Beam.callSync('fs:realpathSync', path);
          if (result.error) throw new Error(result.error);
          return result.data;
        }
        export function renameSync(oldPath, newPath) {
          const result = Beam.callSync('fs:renameSync', oldPath, newPath);
          if (result.error) throw new Error(result.error);
        }
        export function copyFileSync(src, dest) {
          const result = Beam.callSync('fs:copyFileSync', src, dest);
          if (result.error) throw new Error(result.error);
        }
        export async function readFile(path, options) { return readFileSync(path, options); }
        export async function writeFile(path, data, options) { return writeFileSync(path, data, options); }
        export const constants = { F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1 };
        export default { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, statSync, lstatSync, unlinkSync, rmSync, realpathSync, renameSync, copyFileSync, readFile, writeFile, constants };
      `,

      // ============ path shim ============
      'shim:path': `
        export const sep = '/';
        export const delimiter = ':';
        export function join(...parts) {
          return parts.filter(p => p && p.length > 0).join('/').replace(/\\/+/g, '/');
        }
        export function resolve(...parts) {
          let resolved = '';
          for (let i = parts.length - 1; i >= 0; i--) {
            const part = parts[i];
            if (!part) continue;
            resolved = part + (resolved ? '/' + resolved : '');
            if (part.startsWith('/')) break;
          }
          return normalize(resolved || '/');
        }
        export function normalize(path) {
          if (!path) return '.';
          const isAbsolute = path.startsWith('/');
          const parts = path.split('/').filter(p => p && p !== '.');
          const normalized = [];
          for (const part of parts) {
            if (part === '..') {
              if (normalized.length > 0 && normalized[normalized.length - 1] !== '..') normalized.pop();
              else if (!isAbsolute) normalized.push('..');
            } else normalized.push(part);
          }
          let result = normalized.join('/');
          if (isAbsolute) result = '/' + result;
          return result || (isAbsolute ? '/' : '.');
        }
        export function basename(path, ext) {
          let base = path.split('/').pop() || '';
          if (ext && base.endsWith(ext)) base = base.slice(0, -ext.length);
          return base;
        }
        export function dirname(path) {
          const parts = path.split('/'); parts.pop();
          return parts.join('/') || (path.startsWith('/') ? '/' : '.');
        }
        export function extname(path) {
          const base = basename(path);
          const dotIndex = base.lastIndexOf('.');
          return dotIndex <= 0 ? '' : base.slice(dotIndex);
        }
        export function isAbsolute(path) { return path.startsWith('/'); }
        export function relative(from, to) {
          const fromParts = resolve(from).split('/').filter(Boolean);
          const toParts = resolve(to).split('/').filter(Boolean);
          let common = 0;
          for (let i = 0; i < Math.min(fromParts.length, toParts.length); i++) {
            if (fromParts[i] === toParts[i]) common++; else break;
          }
          return [...Array(fromParts.length - common).fill('..'), ...toParts.slice(common)].join('/') || '.';
        }
        export function parse(path) {
          const dir = dirname(path), base = basename(path), ext = extname(path);
          return { root: path.startsWith('/') ? '/' : '', dir, base, ext, name: base.slice(0, base.length - ext.length) };
        }
        export function format(p) { return (p.dir || p.root || '') + '/' + (p.base || (p.name || '') + (p.ext || '')); }
        export const posix = { sep, delimiter, join, resolve, normalize, basename, dirname, extname, isAbsolute, relative, parse, format };
        export default { sep, delimiter, join, resolve, normalize, basename, dirname, extname, isAbsolute, relative, parse, format, posix };
      `,

      // ============ os shim ============
      'shim:os': `
        export function platform() { return Beam.callSync('os:platform'); }
        export function arch() { return Beam.callSync('os:arch'); }
        export function homedir() { return Beam.callSync('os:homedir'); }
        export function tmpdir() { return Beam.callSync('os:tmpdir'); }
        export function hostname() { return Beam.callSync('os:hostname'); }
        export function type() { const p = platform(); return p === 'darwin' ? 'Darwin' : p === 'linux' ? 'Linux' : p; }
        export function cpus() { return Array(Beam.callSync('os:cpuCount')).fill({ model: 'unknown', speed: 0 }); }
        export function totalmem() { return Beam.callSync('os:totalmem'); }
        export function freemem() { return Beam.callSync('os:freemem'); }
        export function uptime() { return Beam.callSync('os:uptime'); }
        export function release() { return Beam.callSync('os:release'); }
        export function userInfo() { return { username: Beam.callSync('os:username'), homedir: homedir(), shell: Beam.callSync('os:shell') }; }
        export const EOL = '\\n';
        export function endianness() { return 'LE'; }
        export function networkInterfaces() { return {}; }
        export default { platform, arch, homedir, tmpdir, hostname, type, cpus, totalmem, freemem, uptime, release, userInfo, EOL, endianness, networkInterfaces };
      `,

      // ============ child_process shim ============
      'shim:child_process': `
        export function execSync(command, options = {}) {
          const cwd = options.cwd || process.cwd();
          const result = Beam.callSync('child_process:execSync', command, cwd);
          if (result.error) { const e = new Error(result.error); e.status = result.status; throw e; }
          return result.stdout;
        }
        export function spawnSync(cmd, args = [], options = {}) {
          const result = Beam.callSync('child_process:execSync', [cmd, ...args].join(' '), options.cwd || process.cwd());
          return { status: result.status || 0, stdout: result.stdout || '', stderr: result.stderr || '', error: result.error ? new Error(result.error) : null };
        }
        export function spawn() { throw new Error('spawn not supported in QuickBEAM'); }
        export function exec(cmd, opts, cb) { 
          if (typeof opts === 'function') { cb = opts; opts = {}; }
          try { const r = execSync(cmd, opts); cb(null, r, ''); } catch(e) { cb(e, '', ''); }
        }
        export default { execSync, spawnSync, spawn, exec };
      `,

      // ============ events shim ============
      'shim:events': `
        export class EventEmitter {
          constructor() { this._events = new Map(); }
          on(event, listener) { if (!this._events.has(event)) this._events.set(event, []); this._events.get(event).push(listener); return this; }
          addListener(event, listener) { return this.on(event, listener); }
          once(event, listener) { const wrapper = (...args) => { this.off(event, wrapper); listener.apply(this, args); }; wrapper.listener = listener; return this.on(event, wrapper); }
          off(event, listener) { return this.removeListener(event, listener); }
          removeListener(event, listener) { const l = this._events.get(event); if (l) { const i = l.findIndex(x => x === listener || x.listener === listener); if (i !== -1) l.splice(i, 1); } return this; }
          removeAllListeners(event) { if (event) this._events.delete(event); else this._events.clear(); return this; }
          emit(event, ...args) { const l = this._events.get(event); if (l) { for (const fn of [...l]) fn.apply(this, args); return true; } return false; }
          listeners(event) { return this._events.get(event) || []; }
          listenerCount(event) { return this.listeners(event).length; }
          eventNames() { return [...this._events.keys()]; }
          setMaxListeners() { return this; }
          getMaxListeners() { return 10; }
        }
        export default EventEmitter;
      `,

      // ============ readline shim ============
      'shim:readline': `
        import EventEmitter from 'shim:events';
        export class Interface extends EventEmitter {
          constructor(opts) { super(); this.input = opts.input; this.output = opts.output; }
          close() { this.emit('close'); }
          pause() { return this; }
          resume() { return this; }
        }
        export function createInterface(opts) { return new Interface(opts); }
        export default { Interface, createInterface };
      `,
    };

    // Plugin that redirects Node.js imports to our shims
    const shimPlugin = {
      name: 'node-shims',
      setup(build) {
        // Resolve shim imports
        build.onResolve({ filter: /^shim:/ }, args => ({
          path: args.path,
          namespace: 'shim',
        }));

        // Load shim content
        build.onLoad({ filter: /.*/, namespace: 'shim' }, args => ({
          contents: shims[args.path],
          loader: 'js',
        }));

        // Redirect Node.js module imports to shims
        const nodeModules = ['fs', 'path', 'os', 'child_process', 'events', 'readline'];
        for (const mod of nodeModules) {
          build.onResolve({ filter: new RegExp(`^(node:)?${mod}$`) }, () => ({
            path: `shim:${mod}`,
            namespace: 'shim',
          }));
        }
      }
    };

    await esbuild.build({
      entryPoints: ['bridge.ts'],
      bundle: true,
      outfile: 'bridge.bundle.js',
      format: 'iife',
      platform: 'neutral',
      target: 'es2020',
      plugins: [shimPlugin],
      define: {
        'process.env.NODE_ENV': '"production"',
      },
      external: [
        // These won't be used by the SDK core functionality
        'node:crypto', 'node:http', 'node:https', 'node:net', 'node:tls',
        'node:stream', 'node:buffer', 'node:util', 'node:url', 'node:zlib',
        'crypto', 'http', 'https', 'net', 'tls', 'stream', 'buffer', 'util', 'url', 'zlib',
      ],
      logLevel: 'warning',
    });

    console.log('Bundle created successfully');
    """

    path = Path.join(package_dir, "bundle.mjs")
    File.write!(path, script)
    :ok
  end

  defp run_bundle(package_dir) do
    Logger.info("Bundling SDK with shims...")

    case run_command("node", ["bundle.mjs"], package_dir) do
      :ok ->
        bundle_path = Path.join(package_dir, "bridge.bundle.js")

        if File.exists?(bundle_path) do
          size = File.stat!(bundle_path).size
          Logger.info("SDK bundle created: #{div(size, 1024)} KB")
          :ok
        else
          {:error, :bundle_not_created}
        end

      error ->
        error
    end
  end

  defp command_exists?(command), do: System.find_executable(command) != nil

  defp run_command(command, args, cwd) do
    case System.cmd(command, args, cd: cwd, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {command, code, output}}
    end
  end

  @doc "Removes the installed SDK for the configured version."
  @spec uninstall() :: :ok
  def uninstall, do: uninstall(Config.version())

  @spec uninstall(String.t()) :: :ok
  def uninstall(version) do
    package_dir = Path.join(Config.cache_dir(), "pi-coding-agent-#{version}")
    if File.exists?(package_dir), do: File.rm_rf!(package_dir)
    :ok
  end

  @doc "Lists all installed versions."
  @spec list_installed() :: [String.t()]
  def list_installed do
    cache_dir = Config.cache_dir()

    if File.exists?(cache_dir) do
      cache_dir
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, "pi-coding-agent-"))
      |> Enum.map(&String.replace_prefix(&1, "pi-coding-agent-", ""))
      |> Enum.sort(:desc)
    else
      []
    end
  end
end
