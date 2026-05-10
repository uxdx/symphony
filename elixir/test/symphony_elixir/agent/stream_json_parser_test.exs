defmodule SymphonyElixir.Agent.StreamJsonParserTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Agent.StreamJsonParser

  describe "parse/1" do
    test "decodes JSON-lines and skips invalid lines" do
      raw = """
      {"type":"system","subtype":"init","session_id":"sess-1"}
      not-json
      {"type":"result","is_error":false}
      """

      events = StreamJsonParser.parse(raw)
      assert length(events) == 2
      assert hd(events)["type"] == "system"
    end

    test "returns empty list for empty input" do
      assert StreamJsonParser.parse("") == []
      assert StreamJsonParser.parse("\n\n") == []
    end

    test "skips non-map JSON values" do
      assert StreamJsonParser.parse("[1,2,3]\n\"abc\"") == []
    end
  end

  describe "summarize/1" do
    test "captures session_id from system init and result usage" do
      events = [
        %{"type" => "system", "subtype" => "init", "session_id" => "abc"},
        %{
          "type" => "assistant",
          "message" => %{
            "content" => [%{"type" => "tool_use"}, %{"type" => "text"}, %{"type" => "tool_use"}]
          }
        },
        %{
          "type" => "result",
          "is_error" => false,
          "subtype" => "success",
          "usage" => %{"input_tokens" => 100, "output_tokens" => 250}
        }
      ]

      summary = StreamJsonParser.summarize(events)

      assert summary.session_id == "abc"
      assert summary.success == true
      assert summary.tokens_in == 100
      assert summary.tokens_out == 250
      assert summary.stop_reason == "success"
      assert summary.final_kind == :result
      assert summary.tool_calls == 2
      assert summary.rate_limited == false
    end

    test "marks rate_limited when subtype=rate_limit" do
      events = [
        %{"type" => "result", "is_error" => true, "subtype" => "rate_limit"}
      ]

      summary = StreamJsonParser.summarize(events)
      assert summary.rate_limited == true
      assert summary.success == false
    end

    test "reads usage nested inside message" do
      events = [
        %{
          "type" => "result",
          "is_error" => false,
          "message" => %{"usage" => %{"input_tokens" => 5, "output_tokens" => 7}}
        }
      ]

      summary = StreamJsonParser.summarize(events)
      assert summary.tokens_in == 5
      assert summary.tokens_out == 7
    end

    test "default summary on empty events" do
      summary = StreamJsonParser.summarize([])
      assert summary == %{
               session_id: nil,
               success: false,
               rate_limited: false,
               tokens_in: 0,
               tokens_out: 0,
               stop_reason: nil,
               final_kind: :unknown,
               tool_calls: 0
             }
    end

    test "ignores unknown event types and assistant without list content" do
      events = [
        %{"type" => "ping"},
        %{"type" => "assistant", "message" => %{"content" => "string-not-list"}}
      ]

      summary = StreamJsonParser.summarize(events)
      assert summary.tool_calls == 0
      assert summary.final_kind == :unknown
    end
  end
end
