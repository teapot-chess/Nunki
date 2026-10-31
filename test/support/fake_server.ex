defmodule Nunki.FakeServer do
  @moduledoc """
  An OpenPairings that is only the hall link: `POST <prefix>/p/nunki/join/:code`
  and the socket at `<prefix>/p/nunki/link`, on a port of its own. It keeps
  every frame it was sent, in order, and can be told to refuse, to push a
  frame, or to go away and come back on the same port.
  """

  use Agent

  def start(opts \\ []) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          codes: MapSet.new(Keyword.get(opts, :codes, ["K7Q-4MD"])),
          key: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false),
          join_status: 200,
          joined: nil,
          frames: [],
          sockets: [],
          revoked: false,
          on_welcome: []
        }
      end)

    {:ok, port} = listen(agent, Keyword.get(opts, :port, 0))
    %{agent: agent, port: port}
  end

  defp listen(agent, port) do
    {:ok, pid} =
      Bandit.start_link(
        plug: {__MODULE__.Plug, agent},
        port: port,
        ip: :loopback,
        startup_log: false
      )

    Process.unlink(pid)
    Agent.update(agent, &Map.put(&1, :listener, pid))
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {:ok, port}
  end

  def link(server, code \\ "K7Q-4MD", product \\ "nunki"),
    do: "http://127.0.0.1:#{server.port}/op/p/#{product}/join/#{code}"

  @doc "Takes the listener and every open socket away."
  def down(server) do
    for pid <- get(server, :sockets), do: send(pid, :close)
    Supervisor.stop(get(server, :listener))
    Agent.update(server.agent, &%{&1 | sockets: []})
    server
  end

  def up(server) do
    {:ok, _port} = listen(server.agent, server.port)
    server
  end

  @doc "The frames the device sent, oldest first, decoded."
  def frames(server), do: get(server, :frames) |> Enum.reverse()
  def frames(server, type), do: Enum.filter(frames(server), &(&1["type"] == type))

  def get(server, key), do: Agent.get(server.agent, &Map.fetch!(&1, key))
  def set(server, key, value), do: Agent.update(server.agent, &Map.put(&1, key, value))

  @doc "Sends a frame down every open socket."
  def push(server, frame), do: for(pid <- get(server, :sockets), do: send(pid, {:push, frame}))
end
