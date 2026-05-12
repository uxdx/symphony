defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.CmuxExecBackend
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  # PR7b chain routing:
  #   all active CS Tool chains -> CmuxExecBackend (codex exec)
  # AppServer is retained for fallback/testing but not reached by any active chain.

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    chain = current_chain_name()
    run_codex_exec_turns(workspace, issue, codex_update_recipient, opts, chain || worker_host)
  end

  defp current_chain_name do
    case System.get_env("SYMPHONY_CHAIN_NAME") do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp run_codex_exec_turns(workspace, issue, codex_update_recipient, opts, chain) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    chain_name = chain || "codex-exec"

    Logger.info("Routing #{issue_context(issue)} to CmuxExecBackend (chain=#{chain_name})")

    with {:ok, session} <- CmuxExecBackend.start_session(workspace, chain_name: chain_name) do
      try do
        do_run_codex_exec_turns(
          session,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          1,
          max_turns
        )
      after
        CmuxExecBackend.stop_session(session)
      end
    end
  end

  defp do_run_codex_exec_turns(
         session,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         turn_number,
         max_turns
       ) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    turn_opts =
      opts
      |> Keyword.take([:issue_comment_fetcher, :git_runner, :expected_branch])
      |> Keyword.put(:issue_state_fetcher, issue_state_fetcher)
      |> Keyword.put(:on_message, codex_message_handler(codex_update_recipient, issue))

    case CmuxExecBackend.run_turn(session, prompt, issue, turn_opts) do
      {:ok, summary, new_session} ->
        Logger.info("Completed codex_exec turn for #{issue_context(issue)} session_id=#{summary[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

        case continue_with_issue?(issue, issue_state_fetcher) do
          {:continue, refreshed_issue} when turn_number < max_turns ->
            do_run_codex_exec_turns(
              new_session,
              workspace,
              refreshed_issue,
              codex_update_recipient,
              opts,
              issue_state_fetcher,
              turn_number + 1,
              max_turns
            )

          {:continue, refreshed_issue} ->
            Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} (codex_exec) — returning control to orchestrator")

            :ok

          {:done, _refreshed_issue} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :auth_blocked} ->
        Logger.warning("codex_exec turn skipped for #{issue_context(issue)}: auth realm blocked")
        raise RuntimeError, "auth realm blocked for #{issue_context(issue)}"

      {:error, :rate_limited} ->
        Logger.warning("codex_exec turn skipped for #{issue_context(issue)}: auth realm rate-limited")
        raise RuntimeError, "auth realm rate-limited for #{issue_context(issue)}"

      {:error, reason} ->
        Logger.warning("codex_exec run_turn failed for #{issue_context(issue)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
