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

  Each screen also has a **source**: `"hall"` (Nunki's own broadcast, all of
  the above) or `"web"` (an address, shown full screen in a frame inside the
  hall page: OpenResults' live boards on one monitor, say, while the other
  shows the pairings). The address is kept when the screen goes back to the
  broadcast, so switching back and forth does not mean typing it again.
  `black` still blacks a web page out; `paused` cannot freeze somebody
  else's page and leaves it alone. Addresses are checked by `check_url/1`.

  The third source is `"boards"`: the live boards of the tournament the
  screen shows (its own choice, else the automatic pick), from that
  tournament's page on OpenResults, whose address OpenPairings tells Nunki
  (`results`, kept by `Nunki.Link`). `"boards"` is the selection of boards
  (`check_boards/1`; empty is all of them). It is kept, like the address,
  when the screen goes to another source. `boards_url/2` is what the screen
  then frames; it is nil while the tournament has no OpenResults address.

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
  @sources ~w(hall web boards)
  @max_boards 100
  @max_board_items 20
  @max_board_number 999
  @identify_ms 5_000

  @doc "The screens there are."
  def screens, do: @screens

  @doc "The modes a screen can be in."
  def modes, do: @modes

  @doc "The screen a page asked for, or `hdmi1` for anything else."
  def screen_name(name) when name in @screens, do: name
  def screen_name(_other), do: "hdmi1"

  @doc "`%{\"mode\", \"tournament\", \"source\", \"url\"}` of one screen."
  def screen(name) when name in @screens, do: Map.fetch!(all(), name)

  @doc "Every screen, by name."
  def all do
    stored = stored_screens(Store.setting("screens"))
    Map.new(@screens, &{&1, normalize(stored[&1])})
  end

  defp stored_screens(%{} = map), do: map
  defp stored_screens(_other), do: %{}

  defp normalize(%{} = s) do
    boards =
      case is_binary(s["boards"]) && check_boards(s["boards"]) do
        {:ok, ok} -> ok
        _none -> ""
      end

    url =
      case is_binary(s["url"]) && check_url(s["url"]) do
        {:ok, url} -> url
        _none -> nil
      end

    %{
      "mode" => if(s["mode"] in @modes, do: s["mode"], else: "live"),
      "tournament" => if(is_binary(s["tournament"]), do: s["tournament"]),
      "source" => source(s["source"], url),
      "url" => url,
      "boards" => boards
    }
  end

  defp normalize(_none),
    do: %{
      "mode" => "live",
      "tournament" => nil,
      "source" => "hall",
      "url" => nil,
      "boards" => ""
    }

  defp source("web", url) when is_binary(url), do: "web"
  defp source("boards", _url), do: "boards"
  defp source(_other, _url), do: "hall"

  @doc "The sources a screen can have."
  def sources, do: @sources

  @doc """
  Sets what a screen shows: `"hall"` (the broadcast), `"web"` with an
  address, or `"boards"` with a selection of boards. `"web"` without an
  address uses the one the screen already has; so does `"boards"` without a
  selection (nil), while a given selection (even `""`, all boards) is kept.
  `:ok`, or `{:error, :screen | :source | :no_url | :boards | {:url, reason}}`,
  the reason being one of `check_url/1`'s.
  """
  def put_source(name, source, url \\ nil, boards \\ nil) do
    cond do
      name not in @screens ->
        {:error, :screen}

      source not in @sources ->
        {:error, :source}

      source == "hall" ->
        change(name, &Map.put(&1, "source", "hall"))

      source == "boards" ->
        case if(is_nil(boards), do: {:ok, nil}, else: check_boards(boards)) do
          {:ok, nil} -> change(name, &Map.put(&1, "source", "boards"))
          {:ok, ok} -> change(name, &Map.merge(&1, %{"source" => "boards", "boards" => ok}))
          {:error, _why} -> {:error, :boards}
        end

      true ->
        url = if is_binary(url) and String.trim(url) != "", do: url, else: screen(name)["url"]

        case url && check_url(url) do
          nil -> {:error, :no_url}
          {:ok, ok} -> change(name, &Map.merge(&1, %{"source" => "web", "url" => ok}))
          {:error, why} -> {:error, {:url, why}}
        end
    end
  end

  @doc """
  Whether a selection of boards is acceptable: `{:ok, selection}` (spaces
  taken out) or `{:error, :boards}`. Empty is all of them; otherwise
  comma-separated items, each `N` or `N-M` with 1 <= N <= M <= 999; at most
  20 items, at most 100 characters.
  """
  def check_boards(boards) when is_binary(boards) do
    if String.length(boards) > @max_boards do
      {:error, :boards}
    else
      selection = String.replace(boards, ~r/\s+/u, "")
      items = if selection == "", do: [], else: String.split(selection, ",")

      if length(items) <= @max_board_items and Enum.all?(items, &board_item?/1),
        do: {:ok, selection},
        else: {:error, :boards}
    end
  end

  def check_boards(_other), do: {:error, :boards}

  defp board_item?(item) do
    case Regex.run(~r/\A(\d{1,3})(?:-(\d{1,3}))?\z/, item) do
      [_, n] ->
        board_number?(n)

      [_, n, m] ->
        board_number?(n) and board_number?(m) and String.to_integer(n) <= String.to_integer(m)

      nil ->
        false
    end
  end

  defp board_number?(text), do: String.to_integer(text) in 1..@max_board_number//1

  @doc """
  What a screen with the `boards` source frames: the tournament's live boards
  on OpenResults (following its current round, chrome hidden), cut to the
  selection. Nil without a results address.
  """
  def boards_url(results, boards) when is_binary(results) and results != "" do
    base = String.trim_trailing(results, "/") <> "/live/current/projector?kiosk=1"
    if is_binary(boards) and boards != "", do: base <> "&boards=" <> boards, else: base
  end

  def boards_url(_none, _boards), do: nil

  @max_url 2_000

  @doc """
  Whether an address may be shown on a screen: `{:ok, address}` (trimmed) or
  `{:error, reason}`.

  `https` to anywhere; `http` only to this machine or the hall's own
  network - `localhost`, `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`,
  `192.168.0.0/16`, `::1`, `*.local` - because an unencrypted page from the
  internet is somebody on the way able to put anything on the hall's
  screen. Reasons: `:empty`, `:too_long`, `:invalid`, `:credentials`,
  `:scheme`, `:insecure`.
  """
  def check_url(url) when is_binary(url) do
    url = String.trim(url)

    with :ok <- if(url == "", do: {:error, :empty}, else: :ok),
         :ok <- if(byte_size(url) > @max_url, do: {:error, :too_long}, else: :ok),
         :ok <-
           if(String.match?(url, ~r/[[:space:][:cntrl:]]/), do: {:error, :invalid}, else: :ok),
         %URI{scheme: scheme, host: host} = uri when is_binary(host) and host != "" <-
           URI.parse(url),
         :ok <- if(uri.userinfo, do: {:error, :credentials}, else: :ok),
         :ok <- scheme_ok(String.downcase(scheme || ""), host) do
      {:ok, url}
    else
      {:error, _why} = error -> error
      _no_host -> {:error, :invalid}
    end
  end

  def check_url(_other), do: {:error, :empty}

  defp scheme_ok("https", _host), do: :ok
  defp scheme_ok("http", host), do: if(private_host?(host), do: :ok, else: {:error, :insecure})
  defp scheme_ok(_other, _host), do: {:error, :scheme}

  defp private_host?(host) do
    host = String.downcase(host)

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> private_ip?(ip)
      {:error, _not_an_ip} -> host == "localhost" or String.ends_with?(host, ".local")
    end
  end

  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b in 16..31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_ip?(_other), do: false

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
