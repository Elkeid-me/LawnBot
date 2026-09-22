defmodule LawnBot.Adapters.QQ do
  use GenServer
  require Logger

  @token_url "https://api.bot.qq.com/app/getAppAccessToken"

  def start_link(init_arg) do
    Logger.info("Starting QQ adapter")
    GenServer.start_link(__MODULE__, init_arg)
  end

  @impl true
  def init(%{app_id: app_id, client_secret: client_secret})
      when is_binary(app_id) and is_binary(client_secret) do
    init_state = %{app_id: app_id, client_secret: client_secret}
    {:ok, init_state, {:continue, :fetch_token}}
  end

  @impl true
  def handle_continue(:fetch_token, %{app_id: app_id, client_secret: client_secret} = state) do
    case LawnBot.Utils.HTTP.json_request(:post, @token_url, [], %{
           appId: app_id,
           clientSecret: client_secret
         }) do
      {:ok, %{"access_token" => token, "expires_in" => _expire_time}} ->
        Logger.info("QQ adapter fetched access token successfully")
        {:noreply, Map.put(state, :access_token, token)}

      {:ok, %{"code" => code, "message" => message}} ->
        Logger.error("Failed to fetch QQ access token: #{code} - #{message}")
        {:stop, :failed_to_fetch_token, state}

      {:error, reason} ->
        Logger.error("Error fetching QQ access token: #{inspect(reason)}")
        {:stop, :failed_to_fetch_token, state}
    end
  end
end
