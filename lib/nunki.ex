defmodule Nunki do
  @moduledoc """
  Nunki, the hall announcer: a round-start countdown on a full-screen page,
  and the pairings read aloud through the speakers of the machine it runs
  on. OpenPairings tells it what to say (hall-link-v1, see docs/protocol.md); the machine's
  own speech engine says it (`Nunki.Voice`).

      Nunki.Application
      ├─ Nunki.PubSub              what the pages and the links hear
      ├─ Nunki.Store               state.json: the device, the tournaments, the settings
      ├─ Nunki.Speaker             one utterance at a time, through the OS
      ├─ Nunki.Countdown           the countdowns, on this machine's monotonic clock
      ├─ Nunki.Links               a Nunki.Link per joined tournament
      ├─ LauncherDetails, Updates.Checker
      └─ NunkiWeb.Endpoint         the control page and the hall screen
  """

  @doc "The version that is running."
  def version, do: to_string(Application.spec(:nunki, :vsn))

  @doc "What the device calls itself to the server (`hello`, the join)."
  def software, do: "nunki " <> version()

  @doc "The topic every page listens on for changes in the state."
  def topic, do: "nunki"

  def subscribe, do: Phoenix.PubSub.subscribe(Nunki.PubSub, topic())

  @doc false
  def broadcast(message), do: Phoenix.PubSub.broadcast(Nunki.PubSub, topic(), message)
end
