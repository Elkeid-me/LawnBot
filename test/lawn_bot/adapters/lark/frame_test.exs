defmodule LawnBot.Adapters.Lark.FrameTest do
  use ExUnit.Case, async: true

  alias LawnBot.Adapters.Lark.Frame

  defp roundtrip(frame) do
    assert {:ok, decoded} = frame |> Frame.encode_frame() |> Frame.decode_frame()
    decoded
  end

  test "round-trips a control ping frame" do
    frame = %Frame{
      method: 0,
      service: 42,
      headers: Frame.header_list(%{"type" => "ping"})
    }

    decoded = roundtrip(frame)

    assert decoded.method == 0
    assert decoded.service == 42
    assert Frame.get_header(decoded, "type") == "ping"
  end

  test "round-trips a data frame with large values and a payload" do
    frame = %Frame{
      seq_id: 300,
      log_id: 65_537,
      service: 123_456,
      method: 1,
      headers:
        Frame.header_list(%{
          "type" => "event",
          "message_id" => "msg-1",
          "sum" => "2",
          "seq" => "1"
        }),
      payload: ~s({"hello":"world"}),
      payload_encoding: "json",
      payload_type: "event",
      log_id_new: "log-new"
    }

    decoded = roundtrip(frame)

    assert decoded.seq_id == 300
    assert decoded.log_id == 65_537
    assert decoded.service == 123_456
    assert decoded.method == 1
    assert Frame.headers_map(decoded) == Frame.headers_map(frame)
    assert decoded.payload == frame.payload
    assert decoded.payload_encoding == "json"
    assert decoded.payload_type == "event"
    assert decoded.log_id_new == "log-new"
  end

  test "decodes a hand-written frame" do
    header = <<0x0A, 4, "type", 0x12, 5, "event">>
    binary = <<0x08, 1, 0x20, 1, 0x2A, byte_size(header), header::binary, 0x42, 2, "{}">>

    assert {:ok, frame} = Frame.decode_frame(binary)
    assert frame.seq_id == 1
    assert frame.method == 1
    assert Frame.get_header(frame, "type") == "event"
    assert frame.payload == "{}"
  end

  test "skips unknown fields" do
    binary = <<0x08, 1, 0x50, 7, 0x20, 1>>

    assert {:ok, frame} = Frame.decode_frame(binary)
    assert frame.seq_id == 1
    assert frame.method == 1
  end

  test "rejects truncated frames" do
    assert {:error, %Protobuf.DecodeError{}} = Frame.decode_frame(<<0x08>>)
    assert {:error, %Protobuf.DecodeError{}} = Frame.decode_frame(<<0x42, 5, "ab">>)
  end
end
