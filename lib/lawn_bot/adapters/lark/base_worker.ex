defmodule LawnBot.Adapters.Lark.BaseWorker do
  @moduledoc """
  Generates a platform-specific WebSocket worker.

  The OpenAPI URLs and label are compile-time constants. No adapter or URL
  strings are part of the worker state.
  """

  defmacro __using__(opts) do
    open_api_url = Keyword.fetch!(opts, :open_api_url)
    label = Keyword.fetch!(opts, :label)

    api_urls = %{
      messages: "#{open_api_url}/open-apis/im/v1/messages",
      images: "#{open_api_url}/open-apis/im/v1/images",
      files: "#{open_api_url}/open-apis/im/v1/files"
    }

    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote bind_quoted: [label: label, api_urls: Macro.escape(api_urls)] do
      use WebSockex

      alias :persistent_term, as: PersistentTerm
      alias LawnBot.Adapters.Lark.API
      alias LawnBot.Adapters.Lark.EventProcess
      alias LawnBot.Adapters.Lark.Frame
      alias LawnBot.Adapters.Lark.Utils
      alias LawnBot.Response
      alias LawnBot.TokenStore

      require Logger

      @label label
      @api_urls api_urls
      @messages_url @api_urls.messages
      @fragment_ttl_ms 5_000

      defstruct [
        :name,
        :url,
        :service_id,
        index: 1,
        ping_interval: :infinity,
        ping_ref: nil,
        last_frame_at: 0,
        fragments: %{},
        seq_id: 0
      ]

      @type t :: %__MODULE__{
              name: atom(),
              url: String.t(),
              service_id: integer(),
              index: pos_integer(),
              ping_interval: timeout(),
              ping_ref: reference() | nil,
              last_frame_at: non_neg_integer(),
              fragments: map(),
              seq_id: non_neg_integer()
            }

      @spec start_link(t()) :: {:ok, pid()} | {:error, term()}
      def start_link(%__MODULE__{} = state) do
        opts = [
          async: true,
          handle_initial_conn_failure: true,
          name: Utils.worker_via_tuple(__MODULE__, state.name, state.index)
        ]

        WebSockex.start_link(state.url, __MODULE__, state, opts)
      end

      @spec child_spec(t()) :: Supervisor.child_spec()
      def child_spec(%__MODULE__{} = state) do
        %{
          id: {__MODULE__, state.name, state.index},
          start: {__MODULE__, :start_link, [state]}
        }
      end

      @impl WebSockex
      def handle_connect(_conn, state) do
        state = cancel_ping(%{state | last_frame_at: now_ms(), fragments: %{}})
        send(self(), :ping)
        {:ok, state}
      end

      @impl WebSockex
      def handle_frame({:binary, data}, state) do
        state = %{state | last_frame_at: now_ms()}

        case Frame.decode_frame(data) do
          {:ok, %Frame{method: 0} = frame} ->
            handle_control_frame(frame, state)

          {:ok, %Frame{method: 1} = frame} ->
            handle_data_frame(frame, state)

          {:ok, frame} ->
            Logger.debug("#{log_name(state)} ignoring frame #{inspect(frame)}")
            {:ok, state}

          {:error, reason} ->
            Logger.warning("#{log_name(state)} invalid frame: #{inspect(reason)}")
            {:ok, state}
        end
      end

      def handle_frame(_frame, state), do: {:ok, state}

      @impl WebSockex
      def handle_ping(:ping, state), do: {:reply, :pong, touch(state)}
      def handle_ping({:ping, message}, state), do: {:reply, {:pong, message}, touch(state)}

      @impl WebSockex
      def handle_pong(_pong, state), do: {:ok, touch(state)}

      @impl WebSockex
      def handle_info(:ping, state) do
        if stale?(state) do
          Logger.warning(
            "#{log_name(state)} no inbound frame for #{now_ms() - state.last_frame_at}ms, reconnecting"
          )

          {:close, state}
        else
          state = %{state | seq_id: state.seq_id + 1}
          state = schedule_ping(state)

          {:reply, {:binary, Frame.encode_frame(ping_frame(state))}, state}
        end
      end

      def handle_info(_message, state), do: {:ok, state}

      @impl WebSockex
      def handle_cast(_message, state), do: {:ok, state}

      @impl WebSockex
      def handle_disconnect(status, state) do
        state = cancel_ping(%{state | last_frame_at: 0, fragments: %{}})

        delay = LawnBot.Utils.exp_backoff(max(status.attempt_number, 1))

        Logger.warning("#{log_name(state)} disconnected, reconnecting in #{delay}ms")

        Process.sleep(delay)
        {:reconnect, state}
      end

      defp handle_control_frame(frame, state) do
        case Frame.get_header(frame, "type") do
          "pong" ->
            state = apply_ping_config(state, frame.payload)
            {:ok, schedule_ping(state)}

          "ping" ->
            pong =
              Frame.put_header(
                %Frame{
                  seq_id: frame.seq_id,
                  log_id: frame.log_id,
                  service: frame.service,
                  method: 0
                },
                "type",
                "pong"
              )

            {:reply, {:binary, Frame.encode_frame(pong)}, state}

          _other ->
            {:ok, state}
        end
      end

      defp handle_data_frame(frame, state) do
        {payload, state} = combine_fragments(frame, state)
        state = cleanup_fragments(state)

        if Frame.get_header(frame, "type") == "event" and is_binary(payload) do
          dispatch(payload, state)
        end

        ack = ack_frame(frame)
        {:reply, {:binary, Frame.encode_frame(ack)}, state}
      end

      defp dispatch(payload, state) do
        case JSON.decode(payload) do
          {:ok, event_payload} when is_map(event_payload) ->
            Task.Supervisor.start_child(
              Utils.task_supervisor_via_tuple(__MODULE__, state.name),
              fn -> process_event(event_payload, state) end
            )

          {:ok, other} ->
            Logger.warning("#{log_name(state)} ignoring non-object event: #{inspect(other)}")

          {:error, reason} ->
            Logger.warning("#{log_name(state)} invalid event JSON: #{inspect(reason)}")
        end

        :ok
      end

      defp process_event(payload, state) do
        case EventProcess.to_event(payload, @messages_url) do
          {:ok, event} -> handle_event(event, state)
          :ignore -> :ok
        end
      end

      defp handle_event(event, state) do
        response = safe_handle(PersistentTerm.get(state.name), event, state)
        handle_response(response, state)
      end

      defp safe_handle(handler, event, state) do
        handler.(event)
      rescue
        exception ->
          Logger.error("#{log_name(state)} handler failed: " <> Exception.message(exception))

          %Response{action: :ignore}
      catch
        kind, reason ->
          Logger.error("#{log_name(state)} handler failed: #{inspect({kind, reason})}")

          %Response{action: :ignore}
      end

      defp handle_response(%Response{action: action} = response, state)
           when action in [:reply, :new_message] do
        case API.send_response(@api_urls, state.name, TokenStore.get(state.name), response) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("#{log_name(state)} failed to send response: " <> inspect(reason))
        end
      end

      defp handle_response(_response, _state), do: :ok

      defp log_name(state), do: Utils.worker_name(@label, state.name, state.index)

      defp ping_frame(state) do
        %Frame{
          seq_id: state.seq_id,
          service: state.service_id,
          method: 0,
          headers: Frame.header_list(%{"type" => "ping"})
        }
      end

      defp ack_frame(frame) do
        Frame.put_header(
          %{frame | payload: JSON.encode!(%{"code" => 200, "headers" => %{}, "data" => []})},
          "biz_rt",
          "0"
        )
      end

      defp apply_ping_config(state, payload) when is_binary(payload) and payload != "" do
        case JSON.decode(payload) do
          {:ok, %{"PingInterval" => seconds}} when is_integer(seconds) and seconds > 0 ->
            %{state | ping_interval: max(seconds * 1_000, 10_000)}

          _other ->
            state
        end
      end

      defp apply_ping_config(state, _payload), do: state

      defp combine_fragments(frame, state) do
        sum = int_header(Frame.get_header(frame, "sum"))
        seq = int_header(Frame.get_header(frame, "seq"))
        message_id = Frame.get_header(frame, "message_id")
        payload = frame.payload || <<>>

        if fragmented?(sum, message_id, seq) do
          combine_fragment(state, message_id, sum, seq, payload)
        else
          {payload, state}
        end
      end

      defp fragmented?(sum, message_id, seq) do
        sum > 1 and is_binary(message_id) and seq >= 0 and seq < sum
      end

      defp combine_fragment(state, message_id, sum, seq, payload) do
        now = System.monotonic_time(:millisecond)

        fragment =
          case Map.get(state.fragments, message_id) do
            %{sum: ^sum} = fragment -> fragment
            _other -> %{sum: sum, parts: %{}, updated_at: now}
          end

        parts = Map.put(fragment.parts, seq, payload)

        if Enum.all?(0..(sum - 1), &Map.has_key?(parts, &1)) do
          data = Enum.map_join(0..(sum - 1), fn index -> parts[index] end)
          {data, %{state | fragments: Map.delete(state.fragments, message_id)}}
        else
          fragment = %{fragment | parts: parts, updated_at: now}
          {nil, %{state | fragments: Map.put(state.fragments, message_id, fragment)}}
        end
      end

      defp cleanup_fragments(state) do
        now = System.monotonic_time(:millisecond)

        fragments =
          Map.reject(state.fragments, fn {_message_id, fragment} ->
            now - fragment.updated_at > @fragment_ttl_ms
          end)

        %{state | fragments: fragments}
      end

      defp schedule_ping(state) do
        state = cancel_ping(state)
        %{state | ping_ref: Process.send_after(self(), :ping, state.ping_interval)}
      end

      defp stale?(%{last_frame_at: 0}), do: false

      defp stale?(state) do
        now_ms() - state.last_frame_at > 2 * state.ping_interval + 5_000
      end

      defp now_ms, do: System.monotonic_time(:millisecond)

      defp touch(state), do: %{state | last_frame_at: now_ms()}

      defp cancel_ping(state) do
        case state.ping_ref do
          nil ->
            state

          ref ->
            Process.cancel_timer(ref)
            %{state | ping_ref: nil}
        end
      end

      defp int_header(nil), do: 0

      defp int_header(value) when is_binary(value) do
        case Integer.parse(value) do
          {int, ""} -> int
          _other -> 0
        end
      end
    end
  end
end
