defmodule LawnBot.Adapters.Lark.Frame do
  @moduledoc """
  A protobuf frame used by the Lark/Feishu WebSocket long connection.

  The wire schema is `pbbp2.Frame`:

  - `seq_id` / `log_id`: frame sequence and log identifiers.
  - `service`: service id parsed from the WebSocket URL.
  - `method`: `0` for control frames, `1` for data frames.
  - `headers`: frame metadata such as `type`, `message_id`, `sum` and `seq`.
  - `payload`: JSON payload for events, or the ACK response.
  """

  defstruct seq_id: 0,
            log_id: 0,
            service: 0,
            method: 0,
            headers: %{},
            payload: nil,
            payload_encoding: "",
            payload_type: "",
            log_id_new: ""

  @type t :: %__MODULE__{
          seq_id: non_neg_integer(),
          log_id: non_neg_integer(),
          service: integer(),
          method: 0 | 1,
          headers: %{optional(String.t()) => String.t()},
          payload: binary() | nil,
          payload_encoding: String.t(),
          payload_type: String.t(),
          log_id_new: String.t()
        }
end
