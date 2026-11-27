defmodule LawnBot.Adapters.Lark.APITest do
  use ExUnit.Case, async: false

  alias LawnBot.Adapters.Feishu
  alias LawnBot.Adapters.Lark.API
  alias LawnBot.Response
  alias LawnBot.TestReqStub

  @moduletag capture_log: true

  @bot :LarkAPITestBot
  @token_path "/oauth/v3/token"
  @endpoint_path "/callback/ws/endpoint"
  @messages_path "/open-apis/im/v1/messages"
  @reply_path "/open-apis/im/v1/messages/om-message/reply"
  @images_path "/open-apis/im/v1/images"
  @files_path "/open-apis/im/v1/files"

  setup do
    :persistent_term.put({@bot, :app_id}, "cli-app")
    :persistent_term.put({@bot, :app_secret}, "secret")
    :persistent_term.put({@bot, :permissions}, [])

    previous_req_options = Elixir.Application.fetch_env(:req, :default_options)
    Elixir.Application.put_env(:req, :default_options, adapter: TestReqStub)

    on_exit(fn ->
      :persistent_term.erase({@bot, :app_id})
      :persistent_term.erase({@bot, :app_secret})
      :persistent_term.erase({@bot, :permissions})

      case previous_req_options do
        {:ok, options} -> Elixir.Application.put_env(:req, :default_options, options)
        :error -> Elixir.Application.delete_env(:req, :default_options)
      end
    end)

    :ok
  end

  defp stub(path, %Req.Response{} = response) do
    Process.put({TestReqStub, path}, fn _request -> response end)
  end

  defp stub(path, fun) when is_function(fun, 1) do
    Process.put({TestReqStub, path}, fun)
  end

  defp response(body, status \\ 200), do: Req.Response.new(status: status, body: body)

  defp json_body(request), do: request.body |> IO.iodata_to_binary() |> JSON.decode!()

  defp form_body(request) do
    request.body |> IO.iodata_to_binary() |> URI.decode_query()
  end

  defp token_response do
    response(%{
      "code" => 0,
      "access_token" => "t-token",
      "expires_in" => 7200,
      "token_type" => "Bearer"
    })
  end

  describe "fetch_tenant_token/2" do
    test "uses the OAuth client credentials endpoint without a scope" do
      stub(@token_path, fn request ->
        assert request.url.host == "accounts.feishu.cn"

        assert form_body(request) == %{
                 "grant_type" => "client_credentials",
                 "client_id" => "cli-app",
                 "client_secret" => "secret"
               }

        token_response()
      end)

      assert {:ok, %{access_token: "t-token", expires_in: 7200}} =
               API.fetch_tenant_token(Feishu.token_url(), @bot)
    end

    test "sends configured permissions as the OAuth scope" do
      :persistent_term.put(
        {@bot, :permissions},
        ["im:message:send_as_bot", "im:message.urgent:app_send"]
      )

      stub(@token_path, fn request ->
        assert form_body(request)["scope"] ==
                 "im:message:send_as_bot im:message.urgent:app_send"

        token_response()
      end)

      assert {:ok, %{access_token: "t-token"}} = API.fetch_tenant_token(Feishu.token_url(), @bot)
    end

    test "rejects a missing token" do
      stub(@token_path, response(%{"code" => 0, "expires_in" => 7200}))

      assert {:error, {:invalid_field_type, _message}} =
               API.fetch_tenant_token(Feishu.token_url(), @bot)
    end

    test "rejects an empty access token or a non-integer lifetime" do
      stub(@token_path, response(%{"code" => 0, "access_token" => "", "expires_in" => 7200}))

      assert {:error, {:invalid_field_type, _message}} =
               API.fetch_tenant_token(Feishu.token_url(), @bot)

      stub(
        @token_path,
        response(%{"code" => 0, "access_token" => "t-token", "expires_in" => "7200"})
      )

      assert {:error, {:invalid_field_type, _message}} =
               API.fetch_tenant_token(Feishu.token_url(), @bot)
    end

    test "maps OAuth errors" do
      stub(
        @token_path,
        response(
          %{
            "code" => 20_002,
            "error" => "invalid_client",
            "error_description" => "The client secret is invalid."
          },
          400
        )
      )

      assert {:error, {:lark_api, 400, 20_002, "The client secret is invalid."}} =
               API.fetch_tenant_token(Feishu.token_url(), @bot)
    end
  end

  describe "fetch_ws_endpoint/2" do
    test "returns the websocket endpoint and client configuration" do
      stub(@endpoint_path, fn request ->
        assert json_body(request) == %{"AppID" => "cli-app", "AppSecret" => "secret"}

        response(%{
          "code" => 0,
          "data" => %{
            "URL" => "wss://msg.example.com/ws?device_id=dev-1&service_id=1234",
            "ClientConfig" => %{
              "PingInterval" => 60,
              "ReconnectNonce" => 10,
              "ReconnectInterval" => 20
            }
          }
        })
      end)

      assert {:ok, endpoint} = API.fetch_ws_endpoint(Feishu.ws_endpoint_url(), @bot)
      assert endpoint.url =~ "wss://msg.example.com/ws"
      assert endpoint.service_id == 1234
      assert endpoint.ping_interval == 60_000
    end

    test "rejects an endpoint without a URL" do
      stub(@endpoint_path, response(%{"code" => 0, "data" => %{}}))

      assert {:error, {:invalid_field_type, _message}} =
               API.fetch_ws_endpoint(Feishu.ws_endpoint_url(), @bot)
    end

    test "rejects endpoint data with malformed client configuration" do
      stub(
        @endpoint_path,
        response(%{
          "code" => 0,
          "data" => %{"URL" => "wss://msg.example.com/ws?service_id=1234", "ClientConfig" => %{}}
        })
      )

      assert {:error, {:invalid_field_type, _message}} =
               API.fetch_ws_endpoint(Feishu.ws_endpoint_url(), @bot)

      stub(
        @endpoint_path,
        response(%{
          "code" => 0,
          "data" => %{
            "URL" => "wss://msg.example.com/ws?service_id=1234",
            "ClientConfig" => %{"PingInterval" => "60"}
          }
        })
      )

      assert {:error, {:invalid_field_type, _message}} =
               API.fetch_ws_endpoint(Feishu.ws_endpoint_url(), @bot)
    end

    test "rejects a websocket URL without a valid service_id" do
      for url <- [
            "wss://msg.example.com/ws",
            "wss://msg.example.com/ws?service_id=abc",
            "wss://msg.example.com/ws?service_id="
          ] do
        stub(
          @endpoint_path,
          response(%{
            "code" => 0,
            "data" => %{"URL" => url, "ClientConfig" => %{"PingInterval" => 60}}
          })
        )

        assert {:error, {:invalid_field_type, "missing service_id in websocket URL"}} =
                 API.fetch_ws_endpoint(Feishu.ws_endpoint_url(), @bot)
      end
    end
  end

  describe "send_response/4" do
    test "sends a new text message to a chat" do
      stub(@messages_path, fn request ->
        assert URI.decode_query(request.url.query) == %{"receive_id_type" => "chat_id"}
        assert Req.Request.get_header(request, "authorization") == ["Bearer t-token"]

        assert json_body(request) == %{
                 "receive_id" => "oc-chat",
                 "msg_type" => "text",
                 "content" => ~s({"text":"hello"})
               }

        response(%{"code" => 0, "data" => %{"message_id" => "om-new"}})
      end)

      reply = %Response{
        action: :new_message,
        session_id: "oc-chat",
        session_type: :group,
        text: "hello"
      }

      assert :ok = API.send_response(Feishu.api_urls(), @bot, "t-token", reply)
    end

    test "replies to a message" do
      stub(@reply_path, fn request ->
        assert json_body(request) == %{
                 "msg_type" => "text",
                 "content" => ~s({"text":"pong"})
               }

        response(%{"code" => 0})
      end)

      reply = %Response{
        action: :reply,
        session_id: "oc-chat",
        session_type: :group,
        reply_message_id: "om-message",
        text: "pong"
      }

      assert :ok = API.send_response(Feishu.api_urls(), @bot, "t-token", reply)
    end

    test "uploads an image before sending it" do
      path = Path.join(System.tmp_dir!(), "lark-api-test-#{System.unique_integer([:positive])}.png")
      File.write!(path, "png-data")
      on_exit(fn -> File.rm(path) end)
      filename = Path.basename(path)

      stub(@images_path, fn request ->
        body = IO.iodata_to_binary(request.body)
        assert body =~ ~s(name="image_type")
        assert body =~ "message"
        assert body =~ ~s(filename="#{filename}")
        response(%{"code" => 0, "data" => %{"image_key" => "img-key"}})
      end)

      stub(@messages_path, fn request ->
        assert json_body(request)["msg_type"] == "image"
        assert json_body(request)["content"] == ~s({"image_key":"img-key"})
        response(%{"code" => 0})
      end)

      reply = %Response{
        action: :new_message,
        session_id: "oc-chat",
        session_type: :group,
        attachment: {:path, path}
      }

      assert :ok = API.send_response(Feishu.api_urls(), @bot, "t-token", reply)
    end

    test "uploads a binary as a file" do
      stub(@files_path, fn request ->
        body = IO.iodata_to_binary(request.body)
        assert body =~ ~s(name="file_type")
        assert body =~ "stream"
        assert body =~ ~s(filename="attachment")
        response(%{"code" => 0, "data" => %{"file_key" => "file-key"}})
      end)

      stub(@messages_path, fn request ->
        assert json_body(request)["msg_type"] == "file"
        assert json_body(request)["content"] == ~s({"file_key":"file-key"})
        response(%{"code" => 0})
      end)

      reply = %Response{
        action: :new_message,
        session_id: "oc-chat",
        session_type: :c2c,
        attachment: {:binary, "binary-data"}
      }

      assert :ok = API.send_response(Feishu.api_urls(), @bot, "t-token", reply)
    end

    test "downloads URL attachments before uploading them" do
      stub("/remote/image.png", fn request ->
        assert Req.Request.get_header(request, "authorization") == []

        Req.Response.new(
          status: 200,
          body: "remote-image",
          headers: %{"content-type" => ["image/png"]}
        )
      end)

      stub(@images_path, fn request ->
        assert IO.iodata_to_binary(request.body) =~ ~s(filename="image.png")
        response(%{"code" => 0, "data" => %{"image_key" => "img-remote"}})
      end)

      stub(@messages_path, fn _request -> response(%{"code" => 0}) end)

      reply = %Response{
        action: :new_message,
        session_id: "oc-chat",
        session_type: :c2c,
        attachment: {:url, "https://example.com/remote/image.png"}
      }

      assert :ok = API.send_response(Feishu.api_urls(), @bot, "t-token", reply)
    end

    test "downloads message resources with the tenant token" do
      resource_path = "/open-apis/im/v1/messages/om-image/resources/img-key"

      stub(resource_path, fn request ->
        assert URI.decode_query(request.url.query) == %{"type" => "image"}
        assert Req.Request.get_header(request, "authorization") == ["Bearer t-token"]

        Req.Response.new(
          status: 200,
          body: "image-data",
          headers: %{"content-type" => ["image/jpeg"]}
        )
      end)

      stub(@images_path, fn request ->
        assert IO.iodata_to_binary(request.body) =~ ~s(filename="img-key")
        response(%{"code" => 0, "data" => %{"image_key" => "img-copy"}})
      end)

      stub("/open-apis/im/v1/messages/om-image/reply", fn _request -> response(%{"code" => 0}) end)

      reply = %Response{
        action: :reply,
        session_id: "oc-chat",
        session_type: :group,
        reply_message_id: "om-image",
        attachment: %LawnBot.Attachment{
          url: Feishu.message_resource_url("om-image", "img-key", "image")
        }
      }

      assert :ok = API.send_response(Feishu.api_urls(), @bot, "t-token", reply)
    end

    test "ignores actions that do not send messages" do
      assert :ok =
               API.send_response(Feishu.api_urls(), @bot, "t-token", %Response{action: :ignore})

      refute_receive {:stub_request, _path, _request}, 50
    end

    test "propagates messaging API errors" do
      stub(
        @messages_path,
        response(%{"code" => 230_002, "msg" => "bot is not in the chat"}, 400)
      )

      reply = %Response{
        action: :new_message,
        session_id: "oc-chat",
        session_type: :group,
        text: "hello"
      }

      assert {:error, {:lark_api, 400, 230_002, "bot is not in the chat"}} =
               API.send_response(Feishu.api_urls(), @bot, "t-token", reply)
    end

    test "rejects success responses that do not follow the API schema" do
      stub(@messages_path, response("<html>gateway</html>", 200))

      reply = %Response{
        action: :new_message,
        session_id: "oc-chat",
        session_type: :group,
        text: "hello"
      }

      assert {:error, {:unexpected_response, 200, "<html>gateway</html>"}} =
               API.send_response(Feishu.api_urls(), @bot, "t-token", reply)
    end

    test "rejects image uploads without an image key" do
      path = Path.join(System.tmp_dir!(), "lark-api-test-#{System.unique_integer([:positive])}.png")
      File.write!(path, "png-data")
      on_exit(fn -> File.rm(path) end)

      stub(@images_path, response(%{"code" => 0, "data" => %{}}))

      reply = %Response{
        action: :new_message,
        session_id: "oc-chat",
        session_type: :group,
        attachment: {:path, path}
      }

      assert {:error, {:invalid_field_type, _message}} =
               API.send_response(Feishu.api_urls(), @bot, "t-token", reply)
    end

    test "rejects file uploads without a file key" do
      stub(@files_path, response(%{"code" => 0, "data" => %{}}))

      reply = %Response{
        action: :new_message,
        session_id: "oc-chat",
        session_type: :group,
        attachment: {:binary, "file-data"}
      }

      assert {:error, {:invalid_field_type, _message}} =
               API.send_response(Feishu.api_urls(), @bot, "t-token", reply)
    end

    test "fails when a message resource cannot be downloaded" do
      stub(
        "/open-apis/im/v1/messages/om-image/resources/img-key",
        response(%{"code" => 234_003, "msg" => "invalid file key"}, 400)
      )

      reply = %Response{
        action: :reply,
        session_id: "oc-chat",
        session_type: :group,
        reply_message_id: "om-image",
        attachment: %LawnBot.Attachment{
          url: Feishu.message_resource_url("om-image", "img-key", "image")
        }
      }

      assert {:error, "failed to download attachment: HTTP 400"} =
               API.send_response(Feishu.api_urls(), @bot, "t-token", reply)
    end

    test "rejects attachments without a URL" do
      reply = %Response{
        action: :reply,
        session_id: "oc-chat",
        session_type: :group,
        reply_message_id: "om-message",
        attachment: %LawnBot.Attachment{filename: "empty.png"}
      }

      assert {:error, "attachment has no url"} =
               API.send_response(Feishu.api_urls(), @bot, "t-token", reply)
    end
  end
end
