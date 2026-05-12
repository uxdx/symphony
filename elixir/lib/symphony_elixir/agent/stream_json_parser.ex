defmodule SymphonyElixir.Agent.StreamJsonParser do
  @moduledoc """
  Parser for `claude --print --output-format stream-json` output.

  PR2 implements the bare minimum: parse JSON-lines into events, summarise
  to extract `session_id`, `success`, `stop_reason`, token usage, and tool
  call count. Symphony's full WIP semantics (rate-limit detection from
  `usage` events, partial-message coalescing) are deferred until PR3+ when
  the StreamJsonParser becomes the runtime parser for the orchestrator
  dispatch path.
  """

  @type event :: map()
  @type summary :: %{
          session_id: String.t() | nil,
          success: boolean(),
          rate_limited: boolean(),
          tokens_in: non_neg_integer(),
          tokens_out: non_neg_integer(),
          stop_reason: String.t() | nil,
          final_kind: atom(),
          tool_calls: non_neg_integer()
        }

  @doc "Parse raw JSON-lines stdout into a list of decoded events."
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
    initial = %{
      session_id: nil,
      success: false,
      rate_limited: false,
      tokens_in: 0,
      tokens_out: 0,
      stop_reason: nil,
      final_kind: :unknown,
      tool_calls: 0
    }

    Enum.reduce(events, initial, &fold_event/2)
  end

  defp fold_event(%{"type" => "system", "subtype" => "init"} = ev, acc) do
    %{acc | session_id: Map.get(ev, "session_id") || acc.session_id}
  end

  defp fold_event(%{"type" => "result"} = ev, acc) do
    success = not Map.get(ev, "is_error", false)

    %{
      acc
      | success: success,
        session_id: Map.get(ev, "session_id") || acc.session_id,
        stop_reason: Map.get(ev, "subtype") || acc.stop_reason,
        final_kind: :result,
        tokens_in: acc.tokens_in + read_usage(ev, "input_tokens"),
        tokens_out: acc.tokens_out + read_usage(ev, "output_tokens"),
        rate_limited: acc.rate_limited or rate_limited?(ev)
    }
  end

  defp fold_event(%{"type" => "assistant", "message" => %{"content" => content}}, acc)
       when is_list(content) do
    %{acc | tool_calls: acc.tool_calls + count_tool_uses(content)}
  end

  defp fold_event(_ev, acc), do: acc

  defp read_usage(ev, key) do
    cond do
      is_map(ev["usage"]) and is_integer(ev["usage"][key]) ->
        ev["usage"][key]

      is_map(ev["message"]) and is_map(ev["message"]["usage"]) and
          is_integer(ev["message"]["usage"][key]) ->
        ev["message"]["usage"][key]

      true ->
        0
    end
  end

  defp rate_limited?(ev) do
    case Map.get(ev, "subtype") do
      "rate_limit" -> true
      _ -> false
    end
  end

  defp count_tool_uses(content) do
    Enum.count(content, fn
      %{"type" => "tool_use"} -> true
      _ -> false
    end)
  end
end
