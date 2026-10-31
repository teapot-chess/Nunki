defmodule OpenPairingsNunkiWeb.LinkSocket do
  @moduledoc """
  The server end of an announcer's link (`WebSock`), one process per
  connected announcer. The rules are OpenPairings' hall-link-v1 contract
  and the Nunki repository's `docs/protocol.md`; the frames are
  `OpenPairingsNunki.Protocol`'s.

  The first frame must be `hello`, with the key in it. Until then nothing
  else is listened to, and a link that says nothing for ten seconds is
  closed. After `welcome` the socket:

    * sends `settings` (the announcer's name and room, which live here and
      nowhere else, and the names of the tournament's rooms), and again whenever either changes, from the tournament
      page or from the device's own `settings` frame, but never the same
      pair twice in a row;
    * sends the latest published round (`round`), if there is one, cut to the
      announcer's room when it has one, and the
      running countdown with the seconds that are left of it, if one runs;
    * listens on the core's tournament topic, and on any change looks again
      300 ms later (one look per burst), sending the round only when its
      `rev` differs from the last one sent here, or a newer round went
      public. A round taken back is never sent; a lower round is ignored;
    * passes on what the tournament page sends over the plugin's own topic
      (`countdown`, `countdown_cancel`, `read`, `stop`);
    * says `leave` and hangs up when the announcer is removed.

  Every frame and every WebSocket ping from the device counts as "seen".
  """
  @behaviour WebSock

  require Logger

  alias OpenPairingsNunki.{Hall, Protocol, RoundPayload}
  alias PairingsEngine.Tournaments
  alias PairingsEngine.Tournaments.Tournament

  @hello_ms 10_000
  @debounce_ms 300

  @doc false
  def new_state,
    do: %{announcer: nil, last_round: 0, last_rev: nil, recheck: nil, last_settings: nil}

  @impl true
  def init(_args) do
    Process.send_after(self(), :hello_timeout, @hello_ms)
    {:ok, new_state()}
  end

  ## ---------- frames in ----------

  @impl true
  def handle_in({text, opts}, state) do
    if Keyword.get(opts, :opcode, :text) == :text do
      case Protocol.decode(text) do
        {:ok, frame} -> frame(frame, state)
        {:error, :bad_frame} -> {:ok, state}
      end
    else
      {:ok, state}
    end
  end

  defp frame(%{"type" => "hello"} = hello, %{announcer: nil} = state) do
    with true <- Protocol.accepts?(hello["v"]) || {:error, :version},
         {:ok, announcer} <- Hall.authenticate(hello["device"], hello["key"]),
         %Tournament{} = tournament <-
           Tournaments.get_tournament(announcer.tournament_id) || {:error, :revoked} do
      welcome(announcer, tournament, state)
    else
      {:error, reason} -> refuse(to_string(reason), state)
    end
  end

  # Nothing but hello before hello.
  defp frame(_frame, %{announcer: nil} = state), do: {:ok, state}

  defp frame(%{"type" => "status"} = frame, state) do
    status =
      case frame["status"] do
        %{} = map -> map
        _ -> Map.delete(frame, "type")
      end

    {:ok, %{state | announcer: Hall.put_status(state.announcer, status)}}
  end

  # The device asks to change its name and/or room. A request, not an
  # order: the row decides, and the answer is the `settings` frame the
  # change brings back over the plugin's topic.
  defp frame(%{"type" => "settings"} = frame, state) do
    announcer = Hall.get_announcer(state.announcer.id) || state.announcer

    case Hall.apply_settings(announcer, Map.take(frame, ["name", "room"])) do
      {:error, :room} ->
        # Refused: the server's own settings, plus what it did not like.
        # Not remembered as "sent", so the next real change still goes out.
        state = %{state | announcer: Hall.touch(announcer)}

        case settings_frame(announcer) do
          nil -> {:ok, state}
          settings -> {:push, text(Map.put(settings, :error, "room")), state}
        end

      _ok ->
        {:ok, %{state | announcer: Hall.touch(announcer)}}
    end
  end

  # The tournament was removed on the device: removed here too.
  defp frame(%{"type" => "leave"}, state) do
    Hall.forget(state.announcer)
    {:stop, :normal, %{state | announcer: nil}}
  end

  defp frame(%{"type" => "ping"}, state) do
    state = %{state | announcer: Hall.touch(state.announcer)}
    {:push, text(Protocol.pong()), state}
  end

  defp frame(_other, state), do: {:ok, %{state | announcer: Hall.touch(state.announcer)}}

  defp welcome(announcer, tournament, state) do
    tid = tournament.id
    Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tid))
    Hall.subscribe(tid)
    # An older link of the same announcer is the stale one.
    Hall.supersede(announcer, self())

    state = %{state | announcer: Hall.connected(announcer)}
    {round_frames, state} = round_frames(state)

    countdown_frames =
      case Hall.current_countdown(tid) do
        nil -> []
        cd -> [Hall.countdown_frame(cd)]
      end

    {settings_frames, state} = settings_frames(state)

    frames =
      [Protocol.welcome(Hall.server_name(), tournament) | settings_frames] ++
        round_frames ++ countdown_frames

    {:push, Enum.map(frames, &text/1), state}
  end

  @impl true
  def handle_control({_payload, opts}, %{announcer: %{}} = state) do
    # Bandit answers the ping itself; this only writes down that the
    # device is still there.
    if Keyword.get(opts, :opcode) in [:ping, :pong],
      do: {:ok, %{state | announcer: Hall.touch(state.announcer)}},
      else: {:ok, state}
  end

  def handle_control(_frame, state), do: {:ok, state}

  ## ---------- messages ----------

  @impl true
  def handle_info({:tournament_changed, _tid, _hint}, %{announcer: %{}, recheck: nil} = state),
    do: {:ok, %{state | recheck: Process.send_after(self(), :recheck, @debounce_ms)}}

  def handle_info(:recheck, %{announcer: %{}} = state) do
    # The tournament may have changed its rooms: the settings frame and the
    # round, filtered by the room, both get another look.
    {settings, state} = settings_frames(%{state | recheck: nil})
    {round, state} = round_frames(state)

    case settings ++ round do
      [] -> {:ok, state}
      frames -> {:push, Enum.map(frames, &text/1), state}
    end
  end

  def handle_info({:nunki_send, frame}, %{announcer: %{}} = state),
    do: {:push, text(frame), state}

  def handle_info({:nunki_settings_changed, id}, %{announcer: %{id: id}} = state) do
    # A room change changes the boards the announcer is sent, too.
    {settings, state} = settings_frames(state)
    {round, state} = round_frames(state)

    case settings ++ round do
      [] -> {:ok, state}
      frames -> {:push, Enum.map(frames, &text/1), state}
    end
  end

  def handle_info({:nunki_revoked, id}, %{announcer: %{id: id}} = state),
    do: {:stop, :normal, 1000, [text(Protocol.leave())], %{state | announcer: nil}}

  def handle_info({:nunki_superseded, id, pid}, %{announcer: %{id: id}} = state)
      when pid != self(),
      do: {:stop, :normal, %{state | announcer: nil}}

  def handle_info(:hello_timeout, %{announcer: nil} = state), do: {:stop, :normal, state}

  def handle_info(_other, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{announcer: %{} = announcer}) do
    Hall.disconnected(announcer)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  ## ---------- helpers ----------

  # The settings frame to send now: the row as it is in the database, unless
  # the last one sent here said the same.
  defp settings_frames(state) do
    case Hall.get_announcer(state.announcer.id) do
      nil ->
        {[], state}

      row ->
        frame = settings_frame(row)

        if frame == nil or frame == state.last_settings,
          do: {[], state},
          else: {[frame], %{state | announcer: row, last_settings: frame}}
    end
  end

  defp settings_frame(row) do
    case Tournaments.get_tournament(row.tournament_id) do
      nil ->
        nil

      t ->
        Protocol.settings(row.name, Hall.room_label(t, row), PairingsEngine.Rooms.names(t))
    end
  end

  # The round frame to send now, if the latest published round is newer
  # than, or different from, the last one this socket sent. The payload is
  # the announcer's own: with a room, only that room's boards, and its `rev`
  # moves when the room does.
  defp round_frames(state) do
    row = Hall.get_announcer(state.announcer.id) || state.announcer

    payload =
      case Tournaments.get_tournament(row.tournament_id) do
        nil -> nil
        t -> t |> RoundPayload.latest() |> RoundPayload.for_room(Hall.effective_room(t, row))
      end

    case payload do
      nil ->
        {[], state}

      %{"round" => n} when n < state.last_round ->
        {[], state}

      %{"round" => n, "rev" => rev} when n == state.last_round and rev == state.last_rev ->
        {[], state}

      %{"round" => n, "rev" => rev} = payload ->
        {[Protocol.round(payload)], %{state | last_round: n, last_rev: rev}}
    end
  end

  defp refuse(reason, state) do
    Logger.info("nunki: refused an announcer's hello (#{reason})")
    {:stop, :normal, 1000, [text(Protocol.refused(reason))], state}
  end

  defp text(frame), do: {:text, Protocol.encode(frame)}
end
