defmodule Nunki.Tournaments do
  @moduledoc """
  The joined tournaments, as the control page sees them: joining one from a
  link, removing one, and the line to each (`Nunki.Link`, one per
  tournament under `Nunki.Links`).
  """

  alias Nunki.{Countdown, Join, Link, Store}

  @doc """
  Joins the tournament of a join link: `{:ok, id}` or `{:error, reason}`
  (see `Nunki.Join.redeem/3`).
  """
  def join(link, req_options \\ []) do
    identity = %{
      "v" => Join.version(),
      "device" => Store.device_id(),
      "name" => Store.device_name(),
      "software" => Nunki.software()
    }

    with {:ok, attrs} <- Join.redeem(link, identity, req_options),
         {:ok, id} <- Store.add_tournament(attrs) do
      restart_link(id)
      {:ok, id}
    end
  end

  @doc """
  Removes a tournament here: the server is told (`leave`) when the line is
  up, the countdown goes, and so does everything kept about it.
  """
  def remove(id) do
    {result, _told} = remove_reporting(id)
    result
  end

  @doc """
  Like `remove/1`, and says whether OpenPairings was told: `{result, :told}`
  or `{result, :not_told}` (the line was down, so the key stays valid there
  until somebody removes the device on that side).
  """
  def remove_reporting(id) do
    told =
      case Link.whereis(id) do
        nil -> :not_told
        pid -> Link.leave(pid)
      end

    stop_link(id)
    Countdown.cancel(id)
    {Store.remove_tournament(id), told}
  end

  @doc """
  Asks the server to change this device's name and room in a tournament.
  `name` and `room` are trimmed and cut to 60 characters; an empty name is
  left out of the request (the server keeps the current one anyway), an
  empty room is sent, because it means "no room". `:ok`, or `{:error, :down}`
  with the line down. Nothing is stored: the server's `settings` frame
  answers, and that is what the page shows.
  """
  def change_settings(id, name, room) when is_binary(name) and is_binary(room) do
    name = name |> String.trim() |> String.slice(0, 60)
    room = room |> String.trim() |> String.slice(0, 60)
    attrs = if name == "", do: %{"room" => room}, else: %{"name" => name, "room" => room}
    Link.send_settings(id, attrs)
  end

  @doc "Each joined tournament (without its key) with `up?` and `error` of its line."
  def list do
    for t <- Store.tournaments(), do: Map.merge(t, Map.new(Link.info(t["id"]), &stringify/1))
  end

  defp stringify({key, value}), do: {to_string(key), value}

  @doc "How many lines are up."
  def links_up do
    Enum.count(Store.tournaments(), &Link.info(&1["id"]).up?)
  catch
    :exit, _not_running -> 0
  end

  @doc "Starts a line for every joined tournament (at start-up)."
  def start_links do
    for t <- Store.tournaments(), do: restart_link(t["id"])
    :ok
  end

  @doc false
  def restart_link(id) do
    stop_link(id)
    DynamicSupervisor.start_child(Nunki.Links, {Link, tournament: id})
  end

  defp stop_link(id) do
    case Link.whereis(id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Nunki.Links, pid)
    end
  end
end
