defmodule LawnBot.Adapters.Lark.Frame.Header do
  @moduledoc """
  A key/value header in a `pbbp2.Frame`.
  """

  use Protobuf, syntax: :proto2

  field(:key, 1, type: :string, required: true, default: "")
  field(:value, 2, type: :string, required: true, default: "")
end

defmodule LawnBot.Adapters.Lark.Frame do
  @moduledoc """
  The `pbbp2.Frame` message used by the Lark/Feishu WebSocket long connection.

  The wire struct is defined with the community `protobuf` library. Only small
  helpers for header lookup/update and exception-safe decoding are added here.
  """

  use Protobuf, syntax: :proto2

  alias LawnBot.Adapters.Lark.Frame.Header

  field(:seq_id, 1, type: :uint64, required: true, default: 0)
  field(:log_id, 2, type: :uint64, required: true, default: 0)
  field(:service, 3, type: :int32, required: true, default: 0)
  field(:method, 4, type: :int32, required: true, default: 0)
  field(:headers, 5, repeated: true, type: Header)
  field(:payload_encoding, 6, type: :string, optional: true)
  field(:payload_type, 7, type: :string, optional: true)
  field(:payload, 8, type: :bytes, optional: true)
  field(:log_id_new, 9, type: :string, optional: true)

  @spec encode_frame(t()) :: binary()
  def encode_frame(%__MODULE__{} = frame), do: encode(frame)

  @spec decode_frame(binary()) :: {:ok, t()} | {:error, Exception.t()}
  def decode_frame(binary) when is_binary(binary) do
    {:ok, decode(binary)}
  rescue
    exception in Protobuf.DecodeError -> {:error, exception}
  end

  @spec get_header(t(), String.t()) :: String.t() | nil
  def get_header(%__MODULE__{headers: headers}, key) do
    Enum.find_value(headers, fn
      %Header{key: ^key, value: value} -> value
      _header -> nil
    end)
  end

  @spec put_header(t(), String.t(), String.t()) :: t()
  def put_header(%__MODULE__{headers: headers} = frame, key, value) do
    headers =
      if Enum.any?(headers, &(&1.key == key)) do
        Enum.map(headers, fn
          %Header{key: ^key} = header -> %{header | value: value}
          header -> header
        end)
      else
        headers ++ [%Header{key: key, value: value}]
      end

    %{frame | headers: headers}
  end

  @doc false
  @spec header_list(map()) :: [Header.t()]
  def header_list(headers) when is_map(headers) do
    Enum.map(headers, fn {key, value} -> %Header{key: to_string(key), value: to_string(value)} end)
  end

  @doc false
  @spec headers_map(t()) :: %{optional(String.t()) => String.t()}
  def headers_map(%__MODULE__{headers: headers}) do
    Map.new(headers, fn %Header{key: key, value: value} -> {key, value} end)
  end
end
