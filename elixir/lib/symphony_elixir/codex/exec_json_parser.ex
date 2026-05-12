defmodule SymphonyElixir.Codex.ExecJsonParser do
  @moduledoc """
  Parser for `codex exec --json` JSONL output (PR7b).

  Event shapes observed from `codex exec --json`:
    {"type":"thread.started","thread_id":"<uuid>"}
    {"type":"turn.started"}
    {"type":"item.completed","item":{"id":"...","type":"agent_message","text":"..."}}
    {"type":"item.completed","item":{"id":"...","type":"tool_call",...}}
    {"type":"item.completed","item":{"id":"...","type":"error","message":"..."}}
    {"type":"turn.completed","usage":{"input_tokens":N,"cached_input_tokens":N,"output_tokens":N}}
    {"type":"turn.failed","error":"..."}

  Non-JSON lines (stderr from the codex binary) are silently skipped.
  """

  @type event :: map()
  @type summary :: %{
          session_id: String.t() | nil,
          success: boolean(),
          tokens_in: non_neg_integer(),
          tokens_out: non_neg_integer(),
          stop_reason: String.t() | nil,
          tool_calls: non_neg_integer()
        }

  @doc "Parse raw JSONL stdout into a list of decoded event maps."
  @spec parse(String.t()) :: [event()]
  def parse(raw) when is_binary(raw) do
    raw
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, ev} when is_map(ev) -> [ev]
        _ -> []
      end
    end)
  end

  @doc "Reduce events to a summary map."
  @spec summarize([event()]) :: summary()
  def summarize(events) when is_list(events) do
    Enum.reduce(events, initial_summary(), &fold_event/2)
  end

  defp initial_summary do
    %{
      session_id: nil,
      success: false,
      tokens_in: 0,
      tokens_out: 0,
      stop_reason: nil,
      tool_calls: 0
    }
  end

  defp fold_event(%{"type" => "thread.started", "thread_id" => id}, acc) when is_binary(id) do
    %{acc | session_id: id}
  end

  defp fold_event(%{"type" => "turn.completed", "usage" => usage}, acc) when is_map(usage) do
    %{acc | success: true, stop_reason: "completed", tokens_in: Map.get(usage, "input_tokens", 0), tokens_out: Map.get(usage, "output_tokens", 0)}
  end

  defp fold_event(%{"type" => "turn.completed"}, acc) do
    %{acc | success: true, stop_reason: "completed"}
  end

  defp fold_event(%{"type" => "turn.failed"}, acc) do
    %{acc | success: false, stop_reason: "failed"}
  end

  defp fold_event(%{"type" => "item.completed", "item" => %{"type" => "tool_call"}}, acc) do
    %{acc | tool_calls: acc.tool_calls + 1}
  end

  defp fold_event(_event, acc), do: acc
end
