defmodule Nunki.Hall do
  @moduledoc """
  What the hall sees and hears, as settings that survive a restart: the
  broadcast screens and the sound.

  ## Screens

  Two named screens, `"hdmi1"` and `"hdmi2"` - the two outputs of a box with
  two monitors; a PC with one projector only ever uses the first. `/hall` is
  `hdmi1`, `/hall?screen=hdmi2` the other. Each has

    * a **mode**: `"live"` (follows everything), `"paused"` (stays on what it
      showed when it was paused and ignores every change until it is live
      again) or `"black"` (nothing at all, for between rounds or a prize
      giving);
    * a **tournament**: a joined tournament's local id, or nil for the
      automatic pick (the one whose countdown runs, else the first joined).

  `?t=<id>` on the page still beats both, for whoever opens a screen by hand.

  ## Sound

  On or off. Off means nothing is said at all - not queued, not saved for
  later; a pairing read an hour late is worse than one not read. The default
  is on, unless `NUNKI_AUDIO=off` (`config :nunki, audio_default: false`) -
  only the default: once somebody switches it, what they chose is kept.

  Every change is broadcast on `Nunki.topic/0`: `{:hall_screen, name,
  screen}`, `{:audio, on?}`, and `{:identify, ms}` for `identify/0`.
  """

  alias Nunki.Store

  @screens ~w(hdmi1 hdmi2)
  @modes ~w(live paused black)
  @identify_ms 5_000

  @doc "The screens there are."
  def screens, do: @screens

  @doc "The modes a screen can be in."
  def modes, do: @modes

  @doc "The screen a page asked for, or `hdmi1` for anything else."
  def screen_name(name) when name in @screens, do: name
  def screen_name(_other), do: "hdmi1"

  @doc "`%{\"mode\", \"tournament\"}` of one screen."
  def screen(name) when name in @screens, do: Map.fetch!(all(), name)

  @doc "Every screen, by name."
  def all do
    stored = stored_screens(Store.setting("screens"))
    Map.new(@screens, &{&1, normalize(stored[&1])})
  end

  defp stored_screens(%{} = map), do: map
  defp stored_screens(_other), do: %{}

  defp normalize(%{} = s) do
    %{
      "mode" => if(s["mode"] in @modes, do: s["mode"], else: "live"),
      "tournament" => if(is_binary(s["tournament"]), do: s["tournament"])
    }
  end

  defp normalize(_none), do: %{"mode" => "live", "tournament" => nil}

  @doc "Sets a screen's mode. `:ok` or `{:error, :screen | :mode}`."
  def put_mode(name, mode) do
    cond do
      name not in @screens -> {:error, :screen}
      mode not in @modes -> {:error, :mode}
      true -> change(name, &Map.put(&1, "mode", mode))
    end
  end

  @doc """
  Sets which tournament a screen shows; nil is the automatic pick. `:ok` or
  `{:error, :screen | :tournament}` (not one joined here).
  """
  def put_tournament(name, id) do
    cond do
      name not in @screens ->
        {:error, :screen}

      is_nil(id) ->
        change(name, &Map.put(&1, "tournament", nil))

      is_binary(id) and Store.tournament(id) != nil ->
        change(name, &Map.put(&1, "tournament", id))

      true ->
        {:error, :tournament}
    end
  end

  @doc "A removed tournament is not shown by choice any longer: those screens go back to automatic."
  def forget_tournament(id) do
    for {name, %{"tournament" => ^id}} <- all(), do: change(name, &Map.put(&1, "tournament", nil))
    :ok
  end

  defp change(name, fun) do
    screens =
      Store.update_setting("screens", fn stored ->
        stored = stored_screens(stored)
        Map.put(stored, name, fun.(normalize(stored[name])))
      end)

    Nunki.broadcast({:hall_screen, name, normalize(screens[name])})
    :ok
  end

  @doc """
  Every hall screen shows its own number, very large, for a few seconds, over
  whatever it shows (black included): so that whoever sets up a box with two
  monitors can tell which is which.
  """
  def identify do
    Nunki.broadcast({:identify, @identify_ms})
    :ok
  end

  @doc """
  The tournament a screen shows: the asked-for one (`?t=`), else the screen's
  own choice, else the one with a countdown still to run, else one that has
  just started, else the first.
  """
  def pick(tournaments, countdowns, wanted, chosen) do
    Enum.find(tournaments, &(&1["id"] == wanted)) ||
      Enum.find(tournaments, &(&1["id"] == chosen)) ||
      Enum.find(tournaments, &match?(%{started?: false}, countdowns[&1["id"]])) ||
      Enum.find(tournaments, &Map.has_key?(countdowns, &1["id"])) ||
      List.first(tournaments)
  end

  @doc "The tournament a screen shows now, by itself (no `?t=`), or nil."
  def shown(name) do
    pick(Store.tournaments(), Nunki.Countdown.all(), nil, screen(name)["tournament"])
  end

  # --- sound ----------------------------------------------------------------------

  @doc "Whether Nunki speaks."
  def audio? do
    case Map.fetch(Store.settings(), "audio") do
      {:ok, value} when is_boolean(value) -> value
      _unset -> audio_default()
    end
  end

  @doc "What `audio?/0` is before anybody chose: on, unless `NUNKI_AUDIO=off`."
  def audio_default, do: Application.get_env(:nunki, :audio_default, true)

  @doc "Switches the sound. Off also stops what is being said and forgets the queue."
  def put_audio(on?) when is_boolean(on?) do
    Store.put_setting("audio", on?)
    unless on?, do: Nunki.Speaker.stop()
    Nunki.broadcast({:audio, on?})
    :ok
  end
end
