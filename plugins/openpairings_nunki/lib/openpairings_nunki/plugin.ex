defmodule OpenPairingsNunki.Plugin do
  @moduledoc """
  Nunki, the hall announcer, as an OpenPairings plugin
  (`PairingsEngine.Plugin`).

  An arbiter joins an announcer (a hall PC with speakers running Nunki) to
  a tournament with a one-time link; from then on the announcer holds a
  WebSocket open to this server and hears about every round the moment its
  pairings become public. The arbiter starts the round countdown and the
  reading aloud from the plugin's tournament page. The announcer does the
  talking; this side only decides when.
  """
  @behaviour PairingsEngine.Plugin

  use Gettext, backend: OpenPairingsNunki.Gettext

  alias OpenPairingsNunki.Hall
  alias PairingsEngine.Features
  alias PairingsEngine.Tournaments.Tournament

  # Kept in step with the plugin's heading in the Nunki CHANGELOG.
  @version "0.3.0"

  @feature "nunki_hall_announcer"

  @doc "The `PairingsEngine.Features` key that switches the plugin on for an account."
  def feature, do: @feature

  @impl true
  def id, do: "nunki"

  @impl true
  def name, do: gettext("Hall announcer (Nunki)")

  @impl true
  def description,
    do:
      gettext(
        "Sends each round's pairings to the announcers in the hall the moment they are public, and lets you start the round countdown and the reading aloud from here."
      )

  @impl true
  def version, do: @version

  @impl true
  def start_path, do: "/p/nunki"

  @impl true
  def routes do
    [
      {"/", OpenPairingsNunkiWeb.IndexLive, :index},
      {"/tournaments/:id", OpenPairingsNunkiWeb.TournamentLive, :show}
    ]
  end

  @impl true
  def http_routes do
    [
      {:post, "/join/:code", OpenPairingsNunkiWeb.JoinPlug, []},
      {:get, "/link", OpenPairingsNunkiWeb.LinkPlug, []}
    ]
  end

  # The announcer is set up per tournament and then left alone, which is
  # what the Settings rail is for; the top bar is for what is used every day.
  # The icon is one the core's own source already uses (the stylesheet only
  # builds those), and a megaphone was already in.
  @impl true
  def tournament_settings_entries(scope, %Tournament{} = t) do
    if Features.enabled?(scope, @feature) do
      [
        %{
          id: "nunki",
          label: gettext("Hall announcer"),
          path: "/p/nunki/tournaments/#{t.id}",
          icon: "hero-megaphone-micro",
          group: :publishing
        }
      ]
    else
      []
    end
  end

  @impl true
  def features do
    [
      %{
        key: @feature,
        # The hosted edition is a Belgian server, and every plug-in on it
        # lives in the Belgian pack. "Optional tools for any federation" is
        # where nobody looks, as was pointed out with some force.
        federation: "BEL",
        label: gettext("Hall announcer (Nunki)"),
        description:
          gettext(
            "Adds \"Hall announcer\" to a tournament's Settings: join a hall PC running Nunki, and it reads each round's pairings aloud and shows the countdown to the start of the round."
          )
      }
    ]
  end

  # Manubrium's hall page (OpenPairings' `HallController`): who is online,
  # and the countdown and announcements it may send. `nil` while the feature
  # is off for the tournament owner's account.
  @impl true
  def hall_status(scope, %Tournament{} = t) do
    if Hall.feature_on?(t) do
      %{
        app: "nunki",
        devices:
          for a <- Hall.list_announcers(scope, t) do
            %{
              id: a.id,
              name: a.name,
              room: Hall.room_label(t, a),
              online: Hall.online?(a),
              last_seen_at: a.last_seen_at
            }
          end,
        countdown: countdown_status(t)
      }
    end
  end

  defp countdown_status(t) do
    case Hall.current_countdown(t.id) do
      nil -> nil
      cd -> %{round: cd.round, seconds_left: Hall.seconds_left(cd)}
    end
  end

  @impl true
  def hall_command(scope, %Tournament{} = t, command) do
    if Hall.feature_on?(t), do: run_command(scope, t, command), else: :unsupported
  end

  defp run_command(scope, t, {:announce, canned, text}) do
    Hall.announce(scope, t, canned, text)
  end

  defp run_command(scope, t, {:countdown, minutes}) do
    with {:ok, _cd} <- Hall.start_countdown(scope, t, minutes) do
      {:ok, Hall.online_count(scope, t)}
    end
  end

  defp run_command(scope, t, :cancel_countdown) do
    case Hall.cancel_countdown(scope, t) do
      :ok -> {:ok, Hall.online_count(scope, t)}
      {:error, :none} -> {:ok, 0}
    end
  end

  defp run_command(_scope, _t, _other), do: :unsupported
  @impl true
  def migrations_path, do: Path.expand("../../priv/migrations", __DIR__)
end
