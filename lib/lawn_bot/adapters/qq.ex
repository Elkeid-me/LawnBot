defmodule LawnBot.Adapters.QQ do
  @moduledoc false
  @behaviour LawnBot.Adapter

  use Supervisor

  alias :persistent_term, as: PersistentTerm
  alias LawnBot.Adapters.QQ.Coordinator

  require Logger
  require NimbleOptions

  @type handler :: {:fun, (LawnBot.Event.t() -> LawnBot.Response.t())} | {:module, module()}

  @type valid_intent ::
          :guilds
          | :guild_members
          | :guild_messages
          | :guild_message_reactions
          | :direct_message
          | :group_and_c2c
          | :interaction
          | :message_audit
          | :forums_event
          | :audio_action
          | :public_guild_messages

  @type options() :: [
          app_id: String.t(),
          client_secret: String.t(),
          name: atom(),
          handler: handler(),
          os: String.t(),
          browser: String.t(),
          device: String.t(),
          intents: [valid_intent()],
          shards: pos_integer()
        ]

  @intents %{
    guilds: 1,
    guild_members: 2,
    guild_messages: 512,
    guild_message_reactions: 1_024,
    direct_message: 4_096,
    group_and_c2c: 33_554_432,
    interaction: 67_108_864,
    message_audit: 134_217_728,
    forums_event: 268_435_456,
    audio_action: 536_870_912,
    public_guild_messages: 1_073_741_824
  }

  @default_intents [:guilds, :guild_members, :public_guild_messages]

  @options_schema NimbleOptions.new!(
                    app_id: [
                      type: {:custom, LawnBot.Utils, :check_empty_string, []},
                      type_doc: "`t:String.t/0`, and must be non-empty.",
                      required: true,
                      doc: "QQ Bot APP ID",
                      redact: true
                    ],
                    client_secret: [
                      type: {:custom, LawnBot.Utils, :check_empty_string, []},
                      type_doc: "`t:String.t/0`, and must be non-empty.",
                      required: true,
                      doc: "QQ Bot Client Secret",
                      redact: true
                    ],
                    name: [
                      type: :atom,
                      required: true,
                      doc: "Adapter instance name, used to distinguish different bots"
                    ],
                    handler: [
                      type: :atom,
                      required: false,
                      default: LawnBot.ExampleHandler,
                      doc:
                        "Event handler, can be a function or a module implementing `LawnBot.Handler`"
                    ],
                    os: [
                      type: :string,
                      required: false,
                      default: to_string(elem(:os.type(), 1)),
                      doc: "`$os` field during authentication"
                    ],
                    browser: [
                      type: :string,
                      required: false,
                      default: "LawnBot",
                      doc: "`$browser` field during authentication"
                    ],
                    device: [
                      type: :string,
                      required: false,
                      default: "LawnBot",
                      doc: "`$device` field during authentication"
                    ],
                    intents: [
                      type: {:list, {:in, Map.keys(@intents)}},
                      type_doc: "`t:valid_intent/0`",
                      required: false,
                      default: @default_intents,
                      doc: "List of event intents to subscribe to"
                    ],
                    shards: [
                      type: :pos_integer,
                      required: false,
                      default: 1,
                      doc: "Number of shards for the bot."
                    ]
                  )

  @api_base_url "https://api.bot.qq.com"

  @impl LawnBot.Adapter
  @spec validate_options(options()) ::
          {:ok, options()} | {:error, NimbleOptions.ValidationError.t()}
  def validate_options(opts), do: NimbleOptions.validate(opts, @options_schema)

  @spec start_link(options()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: via_tuple(name))
  end

  @spec child_spec(options()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :name)},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @impl Supervisor
  @spec init(options()) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    Logger.info("Starting #{bot_name(name)}")
    store_configs(opts, name)
    start_children(opts, name)
  end

  @spec shard_supervisor_via_tuple(module()) ::
          {:via, Registry, {LawnBot.AdapterRegistry, {module(), module()}}}
  def shard_supervisor_via_tuple(name),
    do: {:via, Registry, {LawnBot.AdapterRegistry, {LawnBot.Adapters.QQ.ShardSupervisor, name}}}

  @spec task_supervisor_via_tuple(module()) ::
          {:via, Registry, {LawnBot.AdapterRegistry, {module(), module()}}}
  def task_supervisor_via_tuple(name),
    do: {:via, Registry, {LawnBot.AdapterRegistry, {LawnBot.Adapters.QQ.TaskSupervisor, name}}}

  @doc "Name of the bot, used in logs and error messages."
  @spec bot_name(atom()) :: String.t()
  def bot_name(name), do: "QQ Bot: #{name}"

  @spec store_configs(options(), atom()) :: :ok
  defp store_configs(opts, name) do
    handler_module = Keyword.fetch!(opts, :handler)

    PersistentTerm.put(name, fn event ->
      apply(handler_module, :handle_event, [event])
    end)

    Enum.each([:app_id, :client_secret, :shards, :os, :browser, :device], fn key ->
      PersistentTerm.put({name, key}, Keyword.fetch!(opts, key))
    end)

    intents =
      opts
      |> Keyword.fetch!(:intents)
      |> Enum.reduce(0, fn intent, acc -> acc + Map.get(@intents, intent) end)

    PersistentTerm.put({name, :intents}, intents)
  end

  @spec start_children(options(), atom()) ::
          {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
  defp start_children(opts, name) do
    task_supervisor_name = task_supervisor_via_tuple(name)

    finch_pool = Finch.Pool.new(@api_base_url, tag: name)
    pool_size = Keyword.fetch!(opts, :shards) * 16

    shard_supervisor_name = shard_supervisor_via_tuple(name)

    children = [
      {Task.Supervisor, name: task_supervisor_name},
      {Finch.Pool, finch: LawnBot.Finch, pool: finch_pool, size: pool_size},
      {DynamicSupervisor, strategy: :one_for_one, max_seconds: 30, name: shard_supervisor_name},
      {Coordinator, name}
    ]

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 3, max_seconds: 30)
  end

  @spec via_tuple(atom()) :: {:via, Registry, {Registry.registry(), {__MODULE__, atom()}}}
  defp via_tuple(name), do: {:via, Registry, {LawnBot.AdapterRegistry, {__MODULE__, name}}}
end
