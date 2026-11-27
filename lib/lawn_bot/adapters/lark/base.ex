defmodule LawnBot.Adapters.Lark.Base do
  @moduledoc """
  Generates a platform-specific adapter module.

  API URLs, Coordinator, Worker and label are compile-time constants, so the
  generated Supervisor never receives or stores an adapter module at runtime.
  """

  @doc false
  @spec __using__(
          open_api_url: String.t(),
          accounts_url: String.t(),
          coordinator: module(),
          worker: module(),
          label: String.t()
        ) :: Macro.t()

  defmacro __using__(opts) do
    open_api_url = Keyword.fetch!(opts, :open_api_url)
    accounts_url = Keyword.fetch!(opts, :accounts_url)
    coordinator = Keyword.fetch!(opts, :coordinator)
    worker = Keyword.fetch!(opts, :worker)
    label = Keyword.fetch!(opts, :label)

    messages_url = "#{open_api_url}/open-apis/im/v1/messages"
    token_url = "#{accounts_url}/oauth/v3/token"
    ws_endpoint_url = "#{open_api_url}/callback/ws/endpoint"
    images_url = "#{open_api_url}/open-apis/im/v1/images"
    files_url = "#{open_api_url}/open-apis/im/v1/files"

    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote bind_quoted: [
            open_api_url: open_api_url,
            accounts_url: accounts_url,
            coordinator: coordinator,
            worker: worker,
            label: label,
            messages_url: messages_url,
            token_url: token_url,
            ws_endpoint_url: ws_endpoint_url,
            images_url: images_url,
            files_url: files_url
          ] do
      @behaviour LawnBot.Adapter

      use Supervisor

      alias :persistent_term, as: PersistentTerm
      alias LawnBot.Adapters.Lark.Utils

      require Logger

      @open_api_url open_api_url
      @accounts_url accounts_url
      @coordinator_module coordinator
      @worker_module worker
      @label label
      @token_url token_url
      @ws_endpoint_url ws_endpoint_url
      @messages_url messages_url
      @images_url images_url
      @files_url files_url
      @pool_size_per_worker 16

      if Mix.env() == :test do
        @spec base_url() :: String.t()
        def base_url, do: @open_api_url

        @spec accounts_url() :: String.t()
        def accounts_url, do: @accounts_url

        @spec label() :: String.t()
        def label, do: @label

        @spec coordinator_module() :: module()
        def coordinator_module, do: @coordinator_module

        @spec worker_module() :: module()
        def worker_module, do: @worker_module

        @spec token_url() :: String.t()
        def token_url, do: @token_url

        @spec ws_endpoint_url() :: String.t()
        def ws_endpoint_url, do: @ws_endpoint_url

        @spec messages_url() :: String.t()
        def messages_url, do: @messages_url

        @spec api_urls() :: %{messages: String.t(), images: String.t(), files: String.t()}
        def api_urls, do: %{messages: @messages_url, images: @images_url, files: @files_url}

        @spec reply_message_url(String.t()) :: String.t()
        def reply_message_url(message_id), do: @messages_url <> "/" <> message_id <> "/reply"

        @spec message_resource_url(String.t(), String.t(), String.t()) :: String.t()
        def message_resource_url(message_id, key, type) do
          @messages_url <> "/" <> message_id <> "/resources/" <> key <> "?type=" <> type
        end

        @spec upload_image_url() :: String.t()
        def upload_image_url, do: @images_url

        @spec upload_file_url() :: String.t()
        def upload_file_url, do: @files_url
      end

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
                          default: ["im:message", "im:resource"],
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

      @typedoc "Supported options:\n#{NimbleOptions.docs(@options_schema)}"
      @type options() :: [unquote(NimbleOptions.option_typespec(@options_schema))]

      @impl LawnBot.Adapter
      @spec validate_options(options()) ::
              {:ok, options()} | {:error, NimbleOptions.ValidationError.t()}
      def validate_options(opts) do
        if Keyword.keyword?(opts) do
          NimbleOptions.validate(opts, @options_schema)
        else
          {:error, %NimbleOptions.ValidationError{message: "Expected a keyword list"}}
        end
      end

      @spec start_link(options()) :: Supervisor.on_start()
      def start_link(opts) do
        name = Keyword.fetch!(opts, :name)
        Supervisor.start_link(__MODULE__, opts, name: Utils.supervisor_via_tuple(__MODULE__, name))
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

        Logger.info("Starting #{Utils.bot_name(@label, name)}.")
        store_configs(opts, name)
        start_children(opts, name)
      end

      @spec start_children(options(), atom()) ::
              {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
      defp start_children(opts, name) do
        workers = Keyword.fetch!(opts, :workers)
        finch_pool = Finch.Pool.new(@open_api_url, tag: name)
        pool_size = workers * @pool_size_per_worker
        work_supervisor_name = Utils.worker_supervisor_via_tuple(@worker_module, name)

        children = [
          {Task.Supervisor, name: Utils.task_supervisor_via_tuple(@worker_module, name)},
          {Finch.Pool, finch: LawnBot.Finch, pool: finch_pool, size: pool_size},
          {DynamicSupervisor, strategy: :one_for_one, max_seconds: 30, name: work_supervisor_name},
          {@coordinator_module, {name, workers}}
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
  end
end
