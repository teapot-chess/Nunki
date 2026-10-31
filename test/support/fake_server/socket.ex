defmodule Nunki.FakeServer.Socket do
  @moduledoc false
  @behaviour WebSock

  def init(agent) do
    me = self()
    Agent.update(agent, &%{&1 | sockets: [me | &1.sockets]})
    {:ok, %{agent: agent}}
  catch
    :exit, _gone -> {:stop, :normal, %{agent: agent}}
  end

  def handle_in({text, opcode: :text}, state) do
    frame = Jason.decode!(text)
    Agent.update(state.agent, &%{&1 | frames: [frame | &1.frames]})
    handle(frame, state)
  catch
    # The test that owned the server is over; its device has not noticed yet.
    :exit, _gone -> {:stop, :normal, state}
  end

  def handle_in(_other, state), do: {:ok, state}

  def handle_info({:push, frame}, state), do: {:push, {:text, Jason.encode!(frame)}, state}
  def handle_info(:close, state), do: {:stop, :normal, state}
  def handle_info(_other, state), do: {:ok, state}

  defp handle(%{"type" => "hello", "key" => key}, state) do
    server = Agent.get(state.agent, & &1)

    cond do
      server.revoked ->
        {:push, {:text, Jason.encode!(%{"type" => "refused", "reason" => "revoked"})}, state}

      key != server.key ->
        {:push, {:text, Jason.encode!(%{"type" => "refused", "reason" => "key"})}, state}

      true ->
        welcome = %{
          "type" => "welcome",
          "v" => 1,
          "server" => "fake",
          "tournament" => %{"id" => 1, "name" => "Fake Open"}
        }

        frames = [welcome | server.on_welcome]
        {:push, Enum.map(frames, &{:text, Jason.encode!(&1)}), state}
    end
  end

  defp handle(_frame, state), do: {:ok, state}

  def terminate(_reason, state) do
    me = self()
    Agent.update(state.agent, &%{&1 | sockets: List.delete(&1.sockets, me)})
    :ok
  catch
    :exit, _reason -> :ok
  end
end
