defmodule SymphonyElixir.Verification.TodoCode do
  @moduledoc false

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker

  @expected_branch "feature/cs-tool-launch"

  @spec verify(String.t(), map(), Path.t(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def verify(chain, issue, workspace, summary, opts) do
    state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    comment_fetcher = Keyword.get(opts, :issue_comment_fetcher, &Tracker.fetch_issue_comments/1)
    git_runner = Keyword.get(opts, :git_runner, &run_git/2)
    expected_branch = Keyword.get(opts, :expected_branch, @expected_branch)
    issue_id = issue_id(issue)
    identifier = issue_identifier(issue)

    checks = [
      branch_check(workspace, expected_branch, git_runner),
      clean_workspace_check(workspace, git_runner),
      pushed_to_origin_check(workspace, expected_branch, git_runner),
      commit_evidence_check(workspace, identifier, git_runner),
      linear_target_state_check(issue_id, ["Code Review"], state_fetcher),
      workpad_comment_check(issue_id, comment_fetcher)
    ]

    to_result(chain, issue, summary, checks)
  end

  @doc false
  @spec to_result(String.t(), map(), map(), [map()]) :: {:ok, map()} | {:error, map()}
  def to_result(chain, issue, summary, checks) do
    checks = [protocol_success_check(summary) | checks]
    failed = Enum.reject(checks, &(&1.status == :passed))

    base = %{
      status: if(failed == [], do: :passed, else: :failed),
      chain: chain,
      issue_id: issue_id(issue),
      issue_identifier: issue_identifier(issue),
      checks: checks,
      summary: summary
    }

    case failed do
      [] ->
        {:ok, base}

      failed_checks ->
        classification = classify_failures(failed_checks)

        {:error,
         Map.merge(base, %{
           classification: classification,
           reason: Enum.map_join(failed_checks, ", ", & &1.name)
         })}
    end
  end

  @doc false
  @spec branch_check(Path.t(), String.t(), (Path.t(), [String.t()] -> {:ok, String.t()} | {:error, term()})) ::
          map()
  def branch_check(workspace, expected_branch, git_runner) do
    case git_runner.(workspace, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {:ok, branch} ->
        actual = String.trim(branch)

        check(
          "git.expected_branch",
          actual == expected_branch,
          expected_branch,
          actual,
          :human_required
        )

      {:error, reason} ->
        errored_check("git.expected_branch", expected_branch, reason)
    end
  end

  @doc false
  @spec clean_workspace_check(Path.t(), (Path.t(), [String.t()] -> {:ok, String.t()} | {:error, term()})) ::
          map()
  def clean_workspace_check(workspace, git_runner) do
    case git_runner.(workspace, ["status", "--porcelain"]) do
      {:ok, status} ->
        actual = String.trim(status)
        check("git.clean_workspace", actual == "", "clean", actual, :human_required)

      {:error, reason} ->
        errored_check("git.clean_workspace", "clean", reason)
    end
  end

  @doc false
  @spec pushed_to_origin_check(
          Path.t(),
          String.t(),
          (Path.t(), [String.t()] -> {:ok, String.t()} | {:error, term()})
        ) :: map()
  def pushed_to_origin_check(workspace, expected_branch, git_runner) do
    with {:ok, head} <- git_runner.(workspace, ["rev-parse", "HEAD"]),
         {:ok, origin} <- git_runner.(workspace, ["rev-parse", "origin/#{expected_branch}"]) do
      actual = %{head: String.trim(head), origin: String.trim(origin)}

      check(
        "git.pushed_to_origin",
        actual.head == actual.origin,
        "HEAD == origin/#{expected_branch}",
        actual,
        :retryable
      )
    else
      {:error, reason} -> errored_check("git.pushed_to_origin", "origin/#{expected_branch}", reason)
    end
  end

  @doc false
  @spec commit_evidence_check(
          Path.t(),
          String.t() | nil,
          (Path.t(), [String.t()] -> {:ok, String.t()} | {:error, term()})
        ) :: map()
  def commit_evidence_check(_workspace, nil, _git_runner) do
    check("git.commit_evidence", false, "commit message references issue", nil, :retryable)
  end

  def commit_evidence_check(workspace, identifier, git_runner) do
    case git_runner.(workspace, ["log", "-50", "--format=%H%x09%s", "--grep=#{identifier}"]) do
      {:ok, log} ->
        lines =
          log
          |> String.split("\n", trim: true)
          |> Enum.take(5)

        check("git.commit_evidence", lines != [], "commit message references #{identifier}", lines, :retryable)

      {:error, reason} ->
        errored_check("git.commit_evidence", "commit message references #{identifier}", reason)
    end
  end

  @doc false
  @spec linear_target_state_check(
          String.t() | nil,
          [String.t()],
          ([String.t()] -> {:ok, [Issue.t()]} | {:error, term()})
        ) :: map()
  def linear_target_state_check(nil, expected_states, _state_fetcher) do
    check("linear.target_state", false, expected_states, nil, :retryable)
  end

  def linear_target_state_check(issue_id, expected_states, state_fetcher) do
    case state_fetcher.([issue_id]) do
      {:ok, [%Issue{state: state} | _]} ->
        pass = normalize_state(state) in Enum.map(expected_states, &normalize_state/1)
        check("linear.target_state", pass, expected_states, state, :retryable)

      {:ok, []} ->
        check("linear.target_state", false, expected_states, nil, :retryable)

      {:error, reason} ->
        errored_check("linear.target_state", expected_states, reason)
    end
  end

  @doc false
  @spec workpad_comment_check(String.t() | nil, (String.t() -> {:ok, [map()]} | {:error, term()})) ::
          map()
  def workpad_comment_check(nil, _comment_fetcher) do
    check("linear.workpad_marker", false, "## Codex Workpad comment", nil, :retryable)
  end

  def workpad_comment_check(issue_id, comment_fetcher) do
    case comment_fetcher.(issue_id) do
      {:ok, comments} ->
        markers =
          comments
          |> Enum.map(&comment_body/1)
          |> Enum.filter(&workpad_comment?/1)
          |> Enum.take(3)

        check("linear.workpad_marker", markers != [], "## Codex Workpad comment", markers, :retryable)

      {:error, reason} ->
        errored_check("linear.workpad_marker", "## Codex Workpad comment", reason)
    end
  end

  @doc false
  @spec run_git(Path.t(), [String.t()]) :: {:ok, String.t()} | {:error, map()}
  def run_git(workspace, args) when is_binary(workspace) and is_list(args) do
    case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, %{exit_code: code, output: String.trim(out)}}
    end
  end

  @doc false
  @spec issue_id(Issue.t() | map()) :: String.t() | nil
  def issue_id(%Issue{id: id}) when is_binary(id) and id != "", do: id
  def issue_id(%{id: id}) when is_binary(id) and id != "", do: id
  def issue_id(%{"id" => id}) when is_binary(id) and id != "", do: id
  def issue_id(issue), do: issue_identifier(issue)

  @doc false
  @spec issue_identifier(Issue.t() | map()) :: String.t() | nil
  def issue_identifier(%Issue{identifier: id}) when is_binary(id) and id != "", do: id
  def issue_identifier(%{identifier: id}) when is_binary(id) and id != "", do: id
  def issue_identifier(%{"identifier" => id}) when is_binary(id) and id != "", do: id
  def issue_identifier(_issue), do: nil

  defp check(name, true, expected, actual, _classification) do
    %{name: name, status: :passed, expected: expected, actual: actual}
  end

  defp check(name, false, expected, actual, classification) do
    %{
      name: name,
      status: :failed,
      expected: expected,
      actual: actual,
      classification: classification
    }
  end

  defp protocol_success_check(summary) do
    success? = Map.get(summary, :success) == true or Map.get(summary, "success") == true
    stop_reason = Map.get(summary, :stop_reason) || Map.get(summary, "stop_reason")
    check("turn_protocol_success", success?, "successful turn protocol", stop_reason, :retryable)
  end

  defp errored_check(name, expected, reason) do
    %{
      name: name,
      status: :error,
      expected: expected,
      actual: inspect(reason, printable_limit: 500),
      classification: :system
    }
  end

  defp classify_failures(failed_checks) do
    classes =
      failed_checks
      |> Enum.map(&Map.get(&1, :classification, :system))
      |> MapSet.new()

    cond do
      MapSet.member?(classes, :system) -> :system
      MapSet.member?(classes, :human_required) -> :human_required
      true -> :retryable
    end
  end

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""

  defp comment_body(%{"body" => body}) when is_binary(body), do: body
  defp comment_body(%{body: body}) when is_binary(body), do: body
  defp comment_body(_comment), do: ""

  defp workpad_comment?(body) when is_binary(body) do
    String.starts_with?(String.trim_leading(body), "## Codex Workpad")
  end
end
