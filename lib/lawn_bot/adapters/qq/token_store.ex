defmodule LawnBot.Adapters.QQ.TokenStore do
  @moduledoc """
  QQ `access_token` 的存储单元。

  每个适配器持有自己的一张匿名 ETS 表，tid 由 `LawnBot.Adapters.QQ` 的监督树在
  `init/1` 时创建并向下传递，因此表的生命周期与适配器一致：监督树重启时表随之重建，
  无需额外的清理逻辑。

  读取不经过任何进程，所以 handler 任务可以在真正发送前才取 token，不会拿到过期快照。
  """

  alias :ets, as: ETS

  @key :access_token

  @spec new() :: ETS.tid()
  def new, do: ETS.new(:qq_token, [:set, :public, read_concurrency: true])

  @spec put(ETS.tid(), String.t()) :: true
  def put(tid, access_token), do: ETS.insert(tid, {@key, access_token})

  @doc """
  读取当前 token。

  表由适配器监督树持有，生命周期覆盖所有使用者，因此这里假定 token 一定存在。
  """
  @spec get(ETS.tid()) :: String.t()
  def get(tid), do: ETS.lookup_element(tid, @key, 2)
end
