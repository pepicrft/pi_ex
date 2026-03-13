defmodule PiEx.TreeResolver do
  @moduledoc """
  Tree-based npm dependency resolver.

  ## Why not use npm_ex's resolver?

  npm_ex uses PubGrub (via HexSolver) for dependency resolution. PubGrub is
  designed for package managers like Hex where only ONE version of each package
  can exist in the dependency tree. This works great for Elixir but breaks for
  npm packages.

  The npm ecosystem commonly has transitive dependencies that require different
  versions of the same package. For example, the pi SDK depends on:

      @mariozechner/pi-coding-agent
      └── cli-highlight
          └── chalk@4.x        # needs chalk 4
      └── chalk@5.x            # needs chalk 5

  PubGrub sees this as an unsolvable conflict because it thinks there can only
  be ONE chalk version. But npm/pnpm solve this with nested node_modules:

      node_modules/
      ├── chalk/               # v5 (hoisted, most common)
      └── cli-highlight/
          └── node_modules/
              └── chalk/       # v4 (nested, different version)

  This resolver builds a full dependency tree where each package can have its
  own versions of transitive dependencies, matching how npm/pnpm actually work.

  ## Algorithm

  1. Start with root dependencies
  2. For each package, fetch metadata from `NPM.Registry` and pick best version
  3. Recursively resolve that package's dependencies (building a tree)
  4. Flatten the tree: hoist the most common version, nest conflicts

  Uses `NPM.Registry` for fetching package metadata and `NPM.Cache` for
  downloading tarballs (via `PiEx.TreeLinker`).
  """

  require Logger

  @type version_info :: %{
          version: String.t(),
          integrity: String.t(),
          tarball: String.t(),
          dependencies: %{String.t() => String.t()}
        }

  @type resolved :: %{
          hoisted: %{String.t() => version_info()},
          nested: %{String.t() => version_info()}
        }

  @doc """
  Resolve dependencies starting from root deps.

  Returns `{:ok, %{hoisted: ..., nested: ...}}` or `{:error, reason}`.
  """
  @spec resolve(%{String.t() => String.t()}) :: {:ok, resolved()} | {:error, term()}
  def resolve(root_deps) when map_size(root_deps) == 0 do
    {:ok, %{hoisted: %{}, nested: %{}}}
  end

  def resolve(root_deps) do
    case build_tree(root_deps, [], %{}) do
      {:ok, trees, _cache} ->
        result = flatten_trees(trees)
        {:ok, result}

      {:error, _} = error ->
        error
    end
  end

  # Build dependency trees for a set of deps
  defp build_tree(deps, path, cache) do
    Enum.reduce_while(deps, {:ok, [], cache}, fn {name, range}, {:ok, trees, cache} ->
      case resolve_package(name, range, path, cache) do
        {:ok, nil, cache} -> {:cont, {:ok, trees, cache}}
        {:ok, node, cache} -> {:cont, {:ok, [node | trees], cache}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # Resolve a single package and its dependencies
  defp resolve_package(name, range, path, cache) do
    if name in path do
      Logger.debug("Circular dependency detected: #{Enum.join(path, " -> ")} -> #{name}")
      {:ok, nil, cache}
    else
      case get_best_version(name, range, cache) do
        {:ok, version, info, cache} ->
          new_path = [name | path]

          case build_tree(info.dependencies, new_path, cache) do
            {:ok, children, cache} ->
              node = %{
                name: name,
                version: version,
                info: info,
                children: Enum.reject(children, &is_nil/1)
              }

              {:ok, node, cache}

            {:error, _} = error ->
              error
          end

        {:error, _} = error ->
          error
      end
    end
  end

  # Get the best matching version for a package
  defp get_best_version(name, range, cache) do
    {actual_name, actual_range} = parse_alias(name, range)

    case Map.get(cache, {actual_name, actual_range}) do
      nil ->
        case NPM.Registry.get_packument(actual_name) do
          {:ok, packument} ->
            case find_best_version(packument, actual_range) do
              {:ok, version} ->
                info = Map.fetch!(packument.versions, version)

                version_info = %{
                  version: version,
                  integrity: info.dist.integrity,
                  tarball: info.dist.tarball,
                  dependencies: info.dependencies || %{}
                }

                cache = Map.put(cache, {actual_name, actual_range}, {version, version_info})
                {:ok, version, version_info, cache}

              :error ->
                {:error, {:no_matching_version, actual_name, actual_range}}
            end

          {:error, reason} ->
            {:error, {:registry_error, actual_name, reason}}
        end

      {version, info} ->
        {:ok, version, info, cache}
    end
  end

  # Parse npm: alias syntax ("npm:string-width@^4.2.0" -> {"string-width", "^4.2.0"})
  defp parse_alias(name, range) when is_binary(range) do
    if String.starts_with?(range, "npm:") do
      aliased = String.replace_prefix(range, "npm:", "")

      case Regex.run(~r/^(@?[^@]+)@(.+)$/, aliased) do
        [_, pkg, ver] -> {pkg, ver}
        nil -> {aliased, "*"}
      end
    else
      {name, range}
    end
  end

  defp parse_alias(name, range), do: {name, to_string(range)}

  # Find the best (highest) version matching the range
  defp find_best_version(packument, range) do
    versions =
      packument.versions
      |> Map.keys()
      |> Enum.filter(&version_matches?(&1, range))
      |> Enum.sort(&version_compare/2)

    case versions do
      [] -> :error
      [best | _] -> {:ok, best}
    end
  end

  defp version_matches?(version, range) do
    if version == range do
      true
    else
      case NPMSemver.matches?(version, range) do
        {:ok, true} -> true
        true -> true
        _ -> false
      end
    end
  end

  defp version_compare(a, b) do
    case {Version.parse(a), Version.parse(b)} do
      {{:ok, va}, {:ok, vb}} -> Version.compare(va, vb) == :gt
      _ -> a > b
    end
  end

  # Flatten the tree into hoisted and nested packages
  defp flatten_trees(trees) do
    all_packages = collect_packages(trees, [])
    by_name = Enum.group_by(all_packages, fn {name, _version, _info, _path} -> name end)

    {hoisted, nested} =
      Enum.reduce(by_name, {%{}, %{}}, fn {name, occurrences}, {hoisted, nested} ->
        versions = Enum.map(occurrences, fn {_, v, _, _} -> v end)
        hoisted_version = most_common(versions)

        {_, _, info, _} = Enum.find(occurrences, fn {_, v, _, _} -> v == hoisted_version end)
        hoisted = Map.put(hoisted, name, info)

        nested =
          occurrences
          |> Enum.reject(fn {_, v, _, _} -> v == hoisted_version end)
          |> Enum.reduce(nested, fn {_, _version, info, path}, nested ->
            case path do
              [] -> nested
              [parent | _] ->
                nested_key = "#{parent}/node_modules/#{name}"
                Map.put_new(nested, nested_key, info)
            end
          end)

        {hoisted, nested}
      end)

    %{hoisted: hoisted, nested: nested}
  end

  defp collect_packages(trees, path) do
    Enum.flat_map(trees, fn node ->
      current = {node.name, node.version, node.info, path}
      children = collect_packages(node.children, [node.name | path])
      [current | children]
    end)
  end

  defp most_common(list) do
    list
    |> Enum.frequencies()
    |> Enum.max_by(fn {_, count} -> count end)
    |> elem(0)
  end
end
