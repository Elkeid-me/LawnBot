defmodule LawnBot.Adapters.Lark.Base do
  @moduledoc """
  Shared supervisor and option handling for the Lark and Feishu adapters.

  Both platforms expose the same OpenAPI and long-connection protocol. The
  concrete adapter only provides its API base URL and display label.
  """

  use Supervisor

  alias :persistent_term, as: PersistentTerm
  alias LawnBot.Adapters.Lark.BaseCoordinator
  alias LawnBot.Adapters.Lark.Utils

  require Logger

  @options_schema NimbleOptions.new!(
                    app_id: [
                      type: {:custom, LawnBot.Utils, :check_empty_string, []},
                      type_spec: quote(do: String.t()),
                      type_doc: "`t:String.t/0`, and must be non-empty.",
                      required: true,
                      doc: "App ID of the Lark/Feishu application.",
                      redact: true
                    ],
                    app_secret: [
                      type: {:custom, LawnBot.Utils, :check_empty_string, []},
                      type_spec: quote(do: String.t()),
                      type_doc: "`t:String.t/0`, and must be non-empty.",
                      required: true,
                      doc: "App secret of the Lark/Feishu application.",
                      redact: true
                    ],
                    name: [
                      type: :atom,
                      required: true,
                      doc: "Adapter instance name, used to distinguish different bots."
                    ],
                    handler: [
                      type: :atom,
                      required: false,
                      default: LawnBot.ExampleHandler,
                      doc: "Event handler, a module implementing `LawnBot.Handler`."
                    ],
                    permissions: [
                      type: {:list, :string},
                      required: false,
                      default: [],
                      doc:
                        "Application-identity scopes to request for the tenant access token. " <>
                          "They are sent as the OAuth `scope` field. When empty, the platform uses " <>
                          "all scopes activated for the app in the tenant."
                    ],
                    workers: [
                      type: :pos_integer,
                      required: false,
                      default: 1,
                      doc:
                        "Number of WebSocket workers. Lark/Feishu delivers each event to one " <>
                          "randomly selected worker."
                    ]
                  )

  @pool_size_per_worker 16

  @typedoc "Supported options:\n#{NimbleOptions.docs(@options_schema)}"
  @type options() :: [unquote(NimbleOptions.option_typespec(@options_schema))]

  @spec validate_options(options()) ::
          {:ok, options()} | {:error, NimbleOptions.ValidationError.t()}
  def validate_options(opts) do
    if Keyword.keyword?(opts) do
      NimbleOptions.validate(opts, @options_schema)
    else
      {:error, %NimbleOptions.ValidationError{message: "Expected a keyword list"}}
    end
  end

  @spec start_link(options(), module()) :: Supervisor.on_start()
  def start_link(opts, adapter) do
    name = Keyword.fetch!(opts, :name)
    opts = Keyword.put(opts, :adapter, adapter)
    Supervisor.start_link(__MODULE__, opts, name: Utils.adapter_via_tuple(adapter, name))
  end

  @spec child_spec(options(), module()) :: Supervisor.child_spec()
  def child_spec(opts, adapter) do
    %{
      id: {adapter, Keyword.fetch!(opts, :name)},
      start: {adapter, :start_link, [opts]}
    }
  end

  @impl Supervisor
  @spec init(keyword()) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
  def init(opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    name = Keyword.fetch!(opts, :name)
    workers = Keyword.fetch!(opts, :workers)

    Logger.info("Starting #{Utils.bot_name(adapter, name)} with #{workers} worker(s)")
    store_configs(opts, name)

    finch_pool = Finch.Pool.new(adapter.base_url(), tag: name)
    pool_size = workers * @pool_size_per_worker

    children = [
      {Task.Supervisor, name: Utils.task_supervisor_via_tuple(adapter, name)},
      {Finch.Pool, finch: LawnBot.Finch, pool: finch_pool, size: pool_size},
      {DynamicSupervisor,
       strategy: :one_for_one,
       max_seconds: 30,
       name: Utils.worker_supervisor_via_tuple(adapter, name)},
      {BaseCoordinator, {adapter, name, workers}}
    ]

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 3, max_seconds: 30)
  end

  defp store_configs(opts, name) do
    handler = Keyword.fetch!(opts, :handler)

    PersistentTerm.put(name, fn event ->
      apply(handler, :handle_event, [event])
    end)

    Enum.each([:app_id, :app_secret], fn key ->
      PersistentTerm.put({name, key}, Keyword.fetch!(opts, key))
    end)

    permissions = opts |> Keyword.fetch!(:permissions) |> Enum.uniq()
    PersistentTerm.put({name, :permissions}, permissions)
  end
end
