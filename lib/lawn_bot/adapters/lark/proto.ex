defmodule LawnBot.Adapters.Lark.Proto do
  @moduledoc """
  Minimal protobuf codec for the `pbbp2.Frame` messages used by the
  Lark/Feishu WebSocket long connection.

  Only the wire features required by the protocol are implemented: varints,
  length-delimited fields and the frame/header messages. Unknown fields are
  skipped so that newer server fields do not break decoding.
  """

  import Bitwise

  alias LawnBot.Adapters.Lark.Frame

  @wire_varint 0
  @wire_64bit 1
  @wire_length_delimited 2
  @wire_32bit 5

  @spec encode_frame(Frame.t()) :: binary()
  def encode_frame(%Frame{} = frame) do
    IO.iodata_to_binary([
      varint_field(1, frame.seq_id),
      varint_field(2, frame.log_id),
      varint_field(3, frame.service),
      varint_field(4, frame.method),
      headers_field(frame.headers),
      string_field(6, frame.payload_encoding),
      string_field(7, frame.payload_type),
      bytes_field(8, frame.payload),
      string_field(9, frame.log_id_new)
    ])
  end

  @spec decode_frame(binary()) :: {:ok, Frame.t()} | {:error, term()}
  def decode_frame(binary) when is_binary(binary), do: decode_frame_fields(binary, %Frame{})

  defp decode_frame_fields(<<>>, frame), do: {:ok, frame}

  defp decode_frame_fields(binary, frame) do
    with {:ok, key, rest} <- read_varint(binary) do
      field = key >>> 3
      wire_type = key &&& 0x07

      if field == 0 do
        {:error, :invalid_field_number}
      else
        decode_frame_field(field, wire_type, rest, frame)
      end
    end
  end

  defp decode_frame_field(1, @wire_varint, rest, frame) do
    with {:ok, value, rest} <- read_varint(rest) do
      decode_frame_fields(rest, %{frame | seq_id: value})
    end
  end

  defp decode_frame_field(2, @wire_varint, rest, frame) do
    with {:ok, value, rest} <- read_varint(rest) do
      decode_frame_fields(rest, %{frame | log_id: value})
    end
  end

  defp decode_frame_field(3, @wire_varint, rest, frame) do
    with {:ok, value, rest} <- read_varint(rest) do
      decode_frame_fields(rest, %{frame | service: value})
    end
  end

  defp decode_frame_field(4, @wire_varint, rest, frame) do
    with {:ok, value, rest} <- read_varint(rest) do
      decode_frame_fields(rest, %{frame | method: value})
    end
  end

  defp decode_frame_field(5, @wire_length_delimited, rest, frame) do
    with {:ok, data, rest} <- read_length_delimited(rest),
         {:ok, {key, value}} <- decode_header(data) do
      decode_frame_fields(rest, %{frame | headers: Map.put(frame.headers, key, value)})
    end
  end

  defp decode_frame_field(6, @wire_length_delimited, rest, frame) do
    with {:ok, value, rest} <- read_length_delimited(rest) do
      decode_frame_fields(rest, %{frame | payload_encoding: value})
    end
  end

  defp decode_frame_field(7, @wire_length_delimited, rest, frame) do
    with {:ok, value, rest} <- read_length_delimited(rest) do
      decode_frame_fields(rest, %{frame | payload_type: value})
    end
  end

  defp decode_frame_field(8, @wire_length_delimited, rest, frame) do
    with {:ok, value, rest} <- read_length_delimited(rest) do
      decode_frame_fields(rest, %{frame | payload: value})
    end
  end

  defp decode_frame_field(9, @wire_length_delimited, rest, frame) do
    with {:ok, value, rest} <- read_length_delimited(rest) do
      decode_frame_fields(rest, %{frame | log_id_new: value})
    end
  end

  defp decode_frame_field(_field, wire_type, rest, frame) do
    with {:ok, rest} <- skip(wire_type, rest) do
      decode_frame_fields(rest, frame)
    end
  end

  defp decode_header(binary), do: decode_header_fields(binary, %{})

  defp decode_header_fields(<<>>, header), do: {:ok, {header["key"] || "", header["value"] || ""}}

  defp decode_header_fields(binary, header) do
    with {:ok, key, rest} <- read_varint(binary) do
      decode_header_field(key >>> 3, key &&& 0x07, rest, header)
    end
  end

  defp decode_header_field(1, @wire_length_delimited, rest, header) do
    with {:ok, value, rest} <- read_length_delimited(rest) do
      decode_header_fields(rest, Map.put(header, "key", value))
    end
  end

  defp decode_header_field(2, @wire_length_delimited, rest, header) do
    with {:ok, value, rest} <- read_length_delimited(rest) do
      decode_header_fields(rest, Map.put(header, "value", value))
    end
  end

  defp decode_header_field(_field, wire_type, rest, header) do
    with {:ok, rest} <- skip(wire_type, rest) do
      decode_header_fields(rest, header)
    end
  end

  defp varint_field(_field, 0), do: []

  defp varint_field(field, value) when is_integer(value) and value > 0 do
    [varint(field <<< 3), varint(value)]
  end

  defp varint_field(_field, _value), do: []

  defp headers_field(headers) when is_map(headers) do
    Enum.map(headers, fn {key, value} ->
      header =
        IO.iodata_to_binary([
          string_field(1, to_string(key)),
          string_field(2, to_string(value))
        ])

      length_delimited_field(5, header)
    end)
  end

  defp string_field(_field, ""), do: []
  defp string_field(field, value) when is_binary(value), do: length_delimited_field(field, value)
  defp string_field(_field, _value), do: []

  defp bytes_field(_field, nil), do: []

  defp bytes_field(field, value) when is_binary(value), do: length_delimited_field(field, value)

  defp length_delimited_field(field, value) do
    [varint(field <<< 3 ||| @wire_length_delimited), varint(byte_size(value)), value]
  end

  defp varint(0), do: <<0>>
  defp varint(value) when value > 0, do: varint_bytes(value)

  defp varint_bytes(value) when value < 128, do: <<value>>

  defp varint_bytes(value) do
    <<(value &&& 0x7F) ||| 0x80>> <> varint_bytes(value >>> 7)
  end

  defp read_varint(binary), do: read_varint(binary, 0, 0)

  defp read_varint(<<>>, _value, _shift), do: {:error, :unexpected_eof}

  defp read_varint(<<byte, rest::binary>>, value, shift) when shift < 64 do
    value = value ||| (byte &&& 0x7F) <<< shift

    if (byte &&& 0x80) == 0 do
      {:ok, value, rest}
    else
      read_varint(rest, value, shift + 7)
    end
  end

  defp read_varint(_binary, _value, _shift), do: {:error, :varint_overflow}

  defp read_length_delimited(binary) do
    with {:ok, length, rest} <- read_varint(binary) do
      if byte_size(rest) >= length do
        value = binary_part(rest, 0, length)
        tail = binary_part(rest, length, byte_size(rest) - length)
        {:ok, value, tail}
      else
        {:error, :unexpected_eof}
      end
    end
  end

  defp skip(@wire_varint, binary) do
    with {:ok, _value, rest} <- read_varint(binary), do: {:ok, rest}
  end

  defp skip(@wire_64bit, <<_value::64, rest::binary>>), do: {:ok, rest}

  defp skip(@wire_length_delimited, binary) do
    with {:ok, _value, rest} <- read_length_delimited(binary), do: {:ok, rest}
  end

  defp skip(@wire_32bit, <<_value::32, rest::binary>>), do: {:ok, rest}
  defp skip(@wire_64bit, _binary), do: {:error, :unexpected_eof}
  defp skip(@wire_32bit, _binary), do: {:error, :unexpected_eof}
  defp skip(_wire_type, _binary), do: {:error, :unsupported_wire_type}
end
