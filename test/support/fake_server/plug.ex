defmodule Nunki.FakeServer.Plug do
  @moduledoc false
  @behaviour Elixir.Plug

  import Elixir.Plug.Conn

  def init(agent), do: agent

  def call(%{method: "POST", path_info: [_prefix, "p", "nunki", "join", code]} = conn, agent) do
    {:ok, body, conn} = read_body(conn)
    identity = Jason.decode!(body)

    reply =
      Agent.get_and_update(agent, fn state ->
        cond do
          state.join_status != 200 ->
            {{:status, state.join_status}, state}

          MapSet.member?(state.codes, code) ->
            {{:ok, state.key},
             %{state | codes: MapSet.delete(state.codes, code), joined: identity}}

          true ->
            {{:status, 410}, state}
        end
      end)

    case reply do
      {:ok, key} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "key" => key,
            "socket" => "/op/p/nunki/link",
            "server" => "fake",
            "tournament" => %{"id" => 1, "name" => "Fake Open"}
          })
        )

      {:status, status} ->
        send_resp(conn, status, "no")
    end
  end

  def call(%{path_info: [_prefix, "p", "nunki", "link"]} = conn, agent) do
    conn
    |> WebSockAdapter.upgrade(Nunki.FakeServer.Socket, agent, timeout: 120_000)
    |> halt()
  end

  def call(conn, _agent), do: send_resp(conn, 404, "")
end
