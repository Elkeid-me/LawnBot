defmodule LawnBot.Application do
  @moduledoc """
  LawnBot 的 OTP 应用入口。

  应用启动 Registry 与平台适配器监督器，并根据 `:gateways` 配置启动各个平台的适配器。
  未配置任何网关时，应用会返回 `{:error, :no_gateways_configured}`。
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, name: LawnBot.AdapterRegistry, keys: :unique},
      LawnBot.AdapterSupervisor,
      {Finch, name: LawnBot.Finch}
    ]

    with gateways when is_map(gateways) and map_size(gateways) > 0 <-
           Application.get_env(:lawn_bot, :gateways),
         {:ok, pid} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: LawnBot.Supervisor) do
      Enum.each(gateways, &start_adapters/1)
      {:ok, pid}
    else
      {:error, _reason} ->
        Logger.error("Failed to start LawnBot application supervisor.")
        {:error, :cannot_start_supervisor}

      _ ->
        Logger.error("No gateways configured for LawnBot. Please check your configuration.")
        {:error, :no_gateways_configured}
    end
  end

  defp start_adapters({platform, configs}) when is_list(configs),
    do: Enum.each(configs, &LawnBot.AdapterSupervisor.start_adapter(platform, &1))
end

defmodule LawnBot.Event do
  @moduledoc "LawnBot 事件结构体。"
  defstruct [
    :session_type,
    :session_id,
    :message_type,
    :message_id,
    :author_id,
    :content,
    :extra
  ]

  @type t :: %__MODULE__{
          session_type: :group | :c2c | nil,
          session_id: String.t() | nil,
          message_type: :normal | :new_friend | :delete_friend | nil,
          message_id: String.t() | nil,
          author_id: String.t(),
          content: LawnBot.Event.Content.t(),
          extra: map() | nil
        }
end

defmodule LawnBot.Event.Attachment do
  @moduledoc "LawnBot 事件附件结构体。"
  defstruct [:filename, :mime_type, :size, :width, :height, :url]

  @type t :: %__MODULE__{
          filename: String.t(),
          mime_type: String.t(),
          size: non_neg_integer(),
          width: non_neg_integer() | nil,
          height: non_neg_integer() | nil,
          url: String.t()
        }
end

defmodule LawnBot.Event.History do
  @moduledoc false
  @type t :: [LawnBot.Event.Content.t()]
end

defmodule LawnBot.Event.Content do
  @moduledoc false
  defstruct [:text, :attachments, :references]

  @type t ::
          %__MODULE__{
            text: String.t(),
            attachments: [LawnBot.Event.Attachment.t()] | nil,
            references: [LawnBot.Event.Content.t()] | nil
          }
          | LawnBot.Event.History.t()
          | String.t()
          | nil
end

defmodule LawnBot.Reply do
  @moduledoc "LawnBot 回复结构体。"
  defstruct [:action, :event]

  @type t :: %__MODULE__{
          action: :new_message | :reply | :ignore,
          event: LawnBot.Event.t() | nil
        }
end

defmodule LawnBot.Handler do
  @moduledoc """
  LawnBot 事件处理器行为定义。

  事件处理器负责接收 LawnBot 事件并返回相应的回复。
  """
  @callback handle_event(event :: LawnBot.Event.t()) :: LawnBot.Reply.t()
end

defmodule LawnBot.SystemInfo do
  @moduledoc "LawnBot 系统信息结构体。"
  defstruct [
    :os,
    :elixir_version,
    :otp_release_version,
    :lawn_bot_version,
    :mem_total,
    :mem_allocated,
    :mem_worst,
    :worst_pid
  ]

  @type t :: %__MODULE__{
          os: String.t(),
          elixir_version: String.t(),
          otp_release_version: String.t(),
          lawn_bot_version: String.t(),
          mem_total: non_neg_integer(),
          mem_allocated: non_neg_integer(),
          mem_worst: non_neg_integer(),
          worst_pid: pid()
        }

  def get_system_info do
    os = :os.type() |> elem(1) |> Atom.to_string()
    elixir_version = System.version()
    otp_release_version = System.otp_release()
    lawn_bot_version = :lawn_bot |> Application.spec(:vsn) |> to_string()
    {mem_total, mem_allocated, _} = :memsup.get_memory_data()

    %LawnBot.SystemInfo{
      os: os,
      elixir_version: elixir_version,
      otp_release_version: otp_release_version,
      lawn_bot_version: lawn_bot_version,
      mem_total: mem_total,
      mem_allocated: mem_allocated
    }
  end

  def get_system_info_string do
    info = get_system_info()

    "LawnBot 版本: #{info.lawn_bot_version}\n" <>
      "总内存: #{info.mem_total / 1000} kB\n" <>
      "已分配内存: #{info.mem_allocated / 1000} kB\n"
  end
end
