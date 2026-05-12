defmodule Mix.Tasks.Release.Check do
  @moduledoc """
  Checks whether a Symphony checkout is safe to build or restart from.
  """
  @shortdoc "Fails unsafe Symphony release/apply preconditions"

  use Mix.Task

  @switches [
    repo_root: :string,
    pin: :string,
    pin_file: :string,
    built_commit_file: :string,
    allow_dirty: :boolean
  ]

  @runtime_db_files ["state.db", "state.db-shm", "state.db-wal", "events.jsonl"]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)
    validate_options!(invalid)

    repo_root = repo_root!(opts)
    head = git!(repo_root, ["rev-parse", "HEAD"]) |> String.trim()
    dirty_entries = dirty_entries(repo_root)
    pin = release_pin(opts)
    built_commit = built_release_commit(opts)
    runtime_db_paths = runtime_db_paths(repo_root)

    errors =
      []
      |> maybe_add_dirty_error(dirty_entries, Keyword.get(opts, :allow_dirty, false))
      |> maybe_add_pin_error(repo_root, head, pin)
      |> maybe_add_built_commit_error(repo_root, head, pin, built_commit, Keyword.has_key?(opts, :built_commit_file))
      |> maybe_add_runtime_db_error(runtime_db_paths, repo_root)

    if errors == [] do
      Mix.shell().info("release.check: ok head=#{short_commit(head)} pin=#{pin || "n/a"} built_release_commit=#{built_commit || "n/a"} dirty=#{dirty_label(dirty_entries)} runtime_db=outside_repo")

      :ok
    else
      Enum.each(errors, fn error -> Mix.shell().error(error) end)
      Mix.raise("release.check failed with #{length(errors)} issue(s)")
    end
  end

  defp validate_options!(invalid) do
    if invalid != [] do
      Mix.raise("release.check received invalid option(s): #{inspect(invalid)}")
    end
  end

  defp repo_root!(opts) do
    case Keyword.get(opts, :repo_root) do
      nil ->
        File.cwd!()
        |> git!(["rev-parse", "--show-toplevel"])
        |> String.trim()

      path ->
        Path.expand(path)
    end
  end

  defp dirty_entries(repo_root) do
    repo_root
    |> git!(["status", "--porcelain", "--untracked-files=all"])
    |> String.split("\n", trim: true)
  end

  defp release_pin(opts) do
    cond do
      pin = Keyword.get(opts, :pin) ->
        String.trim(pin)

      pin_file = Keyword.get(opts, :pin_file) ->
        pin_file
        |> Path.expand()
        |> File.read!()
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
        |> List.first()

      true ->
        nil
    end
  end

  defp built_release_commit(opts) do
    case Keyword.get(opts, :built_commit_file) do
      nil ->
        nil

      path ->
        path
        |> Path.expand()
        |> File.read!()
        |> String.trim()
        |> case do
          "" -> nil
          commit -> commit
        end
    end
  end

  defp runtime_db_paths(repo_root) do
    @runtime_db_files
    |> Enum.flat_map(fn file_name -> Path.wildcard(Path.join(repo_root, "**/#{file_name}")) end)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp maybe_add_dirty_error(errors, [], _allow_dirty), do: errors
  defp maybe_add_dirty_error(errors, _dirty_entries, true), do: errors

  defp maybe_add_dirty_error(errors, dirty_entries, false) do
    ["dirty checkout: #{Enum.join(dirty_entries, ", ")}" | errors]
  end

  defp maybe_add_pin_error(errors, _repo_root, _head, nil), do: errors

  defp maybe_add_pin_error(errors, repo_root, head, pin) do
    expected = resolve_pin_commit(repo_root, pin)

    if commit_matches?(head, expected) do
      errors
    else
      ["release pin mismatch: pin=#{pin} resolved=#{expected} head=#{head}" | errors]
    end
  end

  defp maybe_add_built_commit_error(errors, _repo_root, _head, _pin, nil, false), do: errors

  defp maybe_add_built_commit_error(errors, _repo_root, _head, _pin, nil, true) do
    ["built release commit file is empty" | errors]
  end

  defp maybe_add_built_commit_error(errors, repo_root, head, pin, built_commit, _provided?) do
    expected = if pin, do: resolve_pin_commit(repo_root, pin), else: head

    if commit_matches?(built_commit, expected) do
      errors
    else
      ["built release commit mismatch: built=#{built_commit} expected=#{expected}" | errors]
    end
  end

  defp maybe_add_runtime_db_error(errors, [], _repo_root), do: errors

  defp maybe_add_runtime_db_error(errors, paths, repo_root) do
    relative_paths = Enum.map(paths, &Path.relative_to(&1, repo_root))
    ["runtime DB files inside repo checkout: #{Enum.join(relative_paths, ", ")}" | errors]
  end

  defp resolve_pin_commit(repo_root, pin) do
    case System.cmd("git", ["-C", repo_root, "rev-parse", "--verify", "#{pin}^{commit}"], stderr_to_stdout: true) do
      {commit, 0} -> String.trim(commit)
      {_out, _code} -> pin
    end
  end

  defp commit_matches?(head, expected) do
    String.starts_with?(head, expected) or String.starts_with?(expected, head)
  end

  defp dirty_label([]), do: "no"
  defp dirty_label(_entries), do: "allowed"

  defp short_commit(commit) when is_binary(commit), do: String.slice(commit, 0, 12)

  defp git!(repo_root, args) do
    case System.cmd("git", ["-C", repo_root | args], stderr_to_stdout: true) do
      {out, 0} ->
        out

      {out, code} ->
        Mix.raise("git #{Enum.join(args, " ")} failed with exit #{code}: #{String.trim(out)}")
    end
  end
end
