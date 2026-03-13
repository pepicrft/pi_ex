defmodule PiEx.TreeLinker do
  @moduledoc """
  Links resolved packages into node_modules.

  ## Why not use npm_ex's linker?

  npm_ex's linker creates a flat node_modules structure where each package
  is symlinked to the global cache. This works when there's only one version
  of each package, but breaks when multiple versions are needed.

  This linker supports nested node_modules for version conflicts:

      node_modules/
      ├── chalk/                    # symlink to cache (v5, hoisted)
      ├── other-package/            # symlink to cache
      └── cli-highlight/
          └── node_modules/
              └── chalk/            # symlink to cache (v4, nested)

  Node.js resolution will find the nested chalk@4 when cli-highlight
  requires it, while other packages get the hoisted chalk@5.

  Uses `NPM.Cache` for downloading and caching package tarballs.
  """

  @type resolved :: PiEx.TreeResolver.resolved()

  @doc """
  Link resolved packages into node_modules directory.
  """
  @spec link(resolved(), String.t()) :: :ok | {:error, term()}
  def link(resolved, node_modules_dir) do
    all_packages =
      Map.merge(
        Map.new(resolved.hoisted, fn {name, info} -> {{:hoisted, name}, info} end),
        Map.new(resolved.nested, fn {path, info} -> {{:nested, path}, info} end)
      )

    with :ok <- ensure_cached(all_packages) do
      create_links(resolved, node_modules_dir)
    end
  end

  defp ensure_cached(packages) do
    packages
    |> Task.async_stream(
      fn {{_type, _path}, info} ->
        name = extract_package_name(info.tarball)
        NPM.Cache.ensure(name, info.version, info.tarball, info.integrity)
      end,
      max_concurrency: 8,
      timeout: 60_000
    )
    |> Enum.reduce(:ok, fn
      {:ok, {:ok, _}}, acc -> acc
      {:ok, :ok}, acc -> acc
      {:ok, {:error, reason}}, _ -> {:error, reason}
      {:exit, reason}, _ -> {:error, reason}
    end)
  end

  defp extract_package_name(tarball) do
    tarball
    |> String.split("/")
    |> Enum.take_while(&(&1 != "-"))
    |> Enum.drop(3)
    |> Enum.join("/")
  end

  defp create_links(resolved, node_modules_dir) do
    File.mkdir_p!(node_modules_dir)

    # Link hoisted packages
    Enum.each(resolved.hoisted, fn {name, info} ->
      cache_path = NPM.Cache.package_dir(name, info.version)
      target = Path.join(node_modules_dir, name)
      link_package(cache_path, target)
    end)

    # Link nested packages
    Enum.each(resolved.nested, fn {nested_path, info} ->
      name = nested_path |> String.split("/") |> List.last()
      cache_path = NPM.Cache.package_dir(name, info.version)
      target = Path.join(node_modules_dir, nested_path)
      link_package(cache_path, target)
    end)

    :ok
  end

  defp link_package(source, target) do
    target |> Path.dirname() |> File.mkdir_p!()
    File.rm_rf!(target)

    case :os.type() do
      {:unix, _} -> File.ln_s!(source, target)
      _ -> File.cp_r!(source, target)
    end
  end
end
