defmodule LawnBot.Adapters.QQ.UtilsTest do
  use ExUnit.Case, async: true

  alias LawnBot.Adapters.QQ.Utils

  describe "check_api_call_error/1" do
    test "maps a QQ err_code response to a qq_api error" do
      response = %Req.Response{
        status: 400,
        body: %{"err_code" => 11_234, "message" => "bad request"}
      }

      assert Utils.check_api_call_error({:ok, response}) ==
               {:error, {:qq_api, 400, 11_234, "bad request"}}
    end

    test "maps a QQ code response to a qq_api error" do
      response = %Req.Response{status: 401, body: %{"code" => 11_244, "message" => "unauthorized"}}

      assert Utils.check_api_call_error({:ok, response}) ==
               {:error, {:qq_api, 401, 11_244, "unauthorized"}}
    end

    test "maps an unexpected body to an unexpected_response error" do
      response = %Req.Response{status: 500, body: "internal error"}

      assert Utils.check_api_call_error({:ok, response}) ==
               {:error, {:unexpected_response, 500, "internal error"}}
    end

    test "maps transport exceptions to their message" do
      exception = %RuntimeError{message: "connection refused"}

      assert Utils.check_api_call_error({:error, exception}) ==
               {:error, "connection refused"}
    end
  end

  describe "names" do
    test "formats the bot name" do
      assert Utils.bot_name(:app) == "QQ Bot: app"
      assert Utils.bot_name(:LawnBot) == "QQ Bot: LawnBot"
    end

    test "builds registry names for the shard supervisor" do
      assert Utils.shard_supervisor_via_tuple(:Bot) ==
               {:via, Registry,
                {LawnBot.AdapterRegistry, {LawnBot.Adapters.QQ.ShardSupervisor, :Bot}}}
    end

    test "builds registry names for the task supervisor" do
      assert Utils.task_supervisor_via_tuple(:Bot) ==
               {:via, Registry,
                {LawnBot.AdapterRegistry, {LawnBot.Adapters.QQ.TaskSupervisor, :Bot}}}
    end
  end
end
