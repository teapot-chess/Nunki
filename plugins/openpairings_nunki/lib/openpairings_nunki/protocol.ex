defmodule OpenPairingsNunki.Protocol do
  @moduledoc """
  The hall-link protocol, version 1, server side: the frames this plugin
  sends an announcer, and reading the ones it sends back. JSON text
  frames, each an object with a `"type"`. The rules are OpenPairings'
  `priv/contracts/hall-link-v1` (vendored in the Nunki repository), with
  Nunki's own notes in its `docs/protocol.md`; this module only spells them.
  """

  @version 1

  @doc "The protocol version this plugin speaks."
  def version, do: @version

  @doc "Whether a client's `v` is one this plugin speaks."
  def accepts?(v), do: v == @version

  @doc "Decodes a text frame to a map with a string `\"type\"`, or `{:error, :bad_frame}`."
  def decode(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{"type" => type} = frame} when is_binary(type) -> {:ok, frame}
      _ -> {:error, :bad_frame}
    end
  end

  @doc "Encodes a frame for the wire."
  def encode(frame), do: Jason.encode!(frame)

  def welcome(server, tournament),
    do: %{
      type: "welcome",
      v: @version,
      server: server,
      tournament: %{id: tournament.id, name: tournament.name}
    }

  def refused(reason) when reason in ~w(version key revoked),
    do: %{type: "refused", reason: reason}

  def round(payload), do: %{type: "round", round: payload}

  def leave, do: %{type: "leave"}

  def countdown(round, seconds_left, id),
    do: %{type: "countdown", round: round, seconds_left: seconds_left, id: id}

  def countdown_cancel(id), do: %{type: "countdown_cancel", id: id}

  def read(round), do: %{type: "read", round: round}

  def stop, do: %{type: "stop"}

  def pong, do: %{type: "pong"}

  @doc """
  The announcer's name and room as this server holds them, and the names
  of the tournament's rooms to choose from. Sent after `welcome` and
  whenever any of it changes; the server is the truth. `error` is added
  when this frame answers a request that was refused (`"room"`).
  """
  def settings(name, room, rooms_available, error \\ nil) do
    frame = %{type: "settings", name: name, room: room, rooms_available: rooms_available}
    if error, do: Map.put(frame, :error, error), else: frame
  end
end
