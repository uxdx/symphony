defmodule SymphonyElixir.Agent.Backend do
  @moduledoc """
  Behaviour for agent backends (claude/codex). Three callbacks form the
  per-issue execution lifecycle.

  Implementations:
    - `SymphonyElixir.Claude.CmuxPrintBackend` — claude --print inside cmux pane
    - (future) `SymphonyElixir.Codex.CmuxPrintBackend` — codex inside cmux pane
  """

  @type session :: %{
          required(:chain) => String.t(),
          required(:workspace) => Path.t(),
          optional(:session_id) => String.t() | nil,
          optional(any) => any
        }

  @type issue :: SymphonyElixir.Linear.Issue.t() | map()
  @type opts :: keyword()
  @type turn_summary :: %{optional(atom) => any}

  @callback start_session(workspace :: Path.t(), opts) ::
              {:ok, session()} | {:error, term()}

  @callback run_turn(session(), prompt :: String.t(), issue(), opts) ::
              {:ok, turn_summary(), session()} | {:error, term()}

  @callback stop_session(session()) :: :ok
end
