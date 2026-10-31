defmodule Nunki.Link do
  @moduledoc """
  The line to one joined tournament: one outgoing WebSocket
  (`Mint.WebSocket`), kept up. Hall devices always dial out, so nobody
  forwards a port anywhere.

  1. Connect, say `hello` with the key. The server says `welcome`, then
     `settings` (this device's name and room in the tournament), and then
     `round` with the latest published round, if there is one.
  2. Say `status` (the voice, whether it is speaking) after the welcome and
     whenever either changes.
  3. Listen: `round` goes to `Nunki.Announcer`, `countdown` and
     `countdown_cancel` to `Nunki.Countdown`, `announce` to the announcer, `read` and `stop` to the
     announcer and the speaker.
  4. `settings` is kept as the server says it: the server is the truth, so
     a change made here (`send_settings/2`) is only a request, shown once
     the server's `settings` frame comes back. With the line down there is
     nobody to ask, and the answer is `{:error, :down}`.
  5. The line goes: try again after a second, then two, up to thirty.

  A ping every 25 seconds keeps a tunnel from deciding the line is idle,
  and a line that has said nothing for 75 is taken for dead.

  Removed in OpenPairings (`leave`, or `refused` with `revoked`), the
  tournament is forgotten here too. Any other refusal is said on the
  control page and tried again in a minute: a key the server does not know
  today may be a server restored from yesterday's backup tomorrow.

  The key travels in `hello` and nowhere else - not in the address, not in
  a log line.
  """

  use GenServer, restart: :transient

  require Logger

  alias Nunki.{Announcer, Countdown, Speaker, Store}

  @ping_ms 25_000
  @dead_ms 75_000
  @max_backoff_ms 30_000
  @refused_backoff_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def child_spec(opts),
    do: %{
      id: {__MODULE__, opts[:tournament]},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }

  @doc "The link process of a tournament, or nil."
  def whereis(tournament) do
    case Registry.lookup(Nunki.LinkRegistry, tournament) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "`%{up?, error}` - whether the line is up, and why not."
  def info(tournament) do
    case whereis(tournament) do
      nil -> %{up?: false, error: nil}
      pid -> GenServer.call(pid, :info)
    end
  catch
    :exit, _reason -> %{up?: false, error: nil}
  end

  @doc """
  Asks the server to change this device's name and/or room in the
  tournament: `attrs` holds `"name"` and/or `"room"`. `:ok` once the frame
  is on the line, `{:error, :down}` when there is no line to send it on.
  Nothing is stored here: the server's answer is.
  """
  def send_settings(tournament, attrs) do
    case whereis(tournament) do
      nil -> {:error, :down}
      pid -> GenServer.call(pid, {:settings, attrs})
    end
  catch
    :exit, _reason -> {:error, :down}
  end

  @doc "Tells the server this device is leaving the tournament, if the line is up."
  def leave(pid) do
    GenServer.call(pid, :leave)
  catch
    :exit, _reason -> :ok
  end

  # --- the process -------------------------------------------------------------

  @impl true
  def init(opts) do
    tournament = Keyword.fetch!(opts, :tournament)
    {:ok, _} = Registry.register(Nunki.LinkRegistry, tournament, nil)
    Nunki.subscribe()
    send(self(), :connect)

    {:ok,
     %{
       tournament: tournament,
       url: nil,
       conn: nil,
       ref: nil,
       websocket: nil,
       upgrade: %{},
       up?: false,
       error: nil,
       backoff: 1_000,
       heard: now(),
       status_sent: nil
     }}
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, %{up?: state.up?, error: state.error}, state}

  def handle_call({:settings, attrs}, _from, %{up?: true} = state) do
    frame = attrs |> Map.take(["name", "room"]) |> Map.put("type", "settings")
    {:reply, :ok, push(state, frame)}
  end

  def handle_call({:settings, _attrs}, _from, state), do: {:reply, {:error, :down}, state}

  def handle_call(:leave, _from, %{up?: true} = state) do
    state = push(state, %{"type" => "leave"})
    {:reply, :ok, close(state) |> Map.put(:stopping, true)}
  end

  def handle_call(:leave, _from, state), do: {:reply, :ok, Map.put(state, :stopping, true)}

  @impl true
  def handle_info(:connect, %{conn: nil} = state) do
    case Store.tournament(state.tournament) do
      nil -> {:stop, :normal, state}
      t -> {:noreply, connect(%{state | url: t["socket"]})}
    end
  end

  def handle_info(:connect, state), do: {:noreply, state}

  def handle_info(:ping, %{up?: true} = state) do
    if now() - state.heard > @dead_ms do
      {:noreply, lost(state, :silent)}
    else
      Process.send_after(self(), :ping, @ping_ms)
      {:noreply, send_frame(state, {:ping, ""})}
    end
  end

  def handle_info(:ping, state), do: {:noreply, state}

  def handle_info(:stop, state), do: {:stop, :normal, state}

  # The voice or the speaking changed: the server hears of it if it is news.
  def handle_info({:speaker, _status}, state), do: {:noreply, send_status(state)}
  def handle_info(:voices_changed, state), do: {:noreply, send_status(state)}
  def handle_info(:state_changed, state), do: {:noreply, send_status(state)}
  def handle_info({:countdown, _tournament}, state), do: {:noreply, state}

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        {:noreply, Enum.reduce(responses, %{state | conn: conn}, &response/2) |> after_frames()}

      {:error, conn, reason, _responses} ->
        {:noreply, lost(%{state | conn: conn}, reason)}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.conn, do: Mint.HTTP.close(state.conn)
    :ok
  end

  # --- the socket --------------------------------------------------------------

  defp connect(state) do
    uri = URI.parse(state.url)
    http = if uri.scheme == "wss", do: :https, else: :http
    ws = if uri.scheme == "wss", do: :wss, else: :ws

    with {:ok, conn} <-
           Mint.HTTP.connect(http, uri.host, uri.port,
             protocols: [:http1],
             transport_opts: [timeout: 10_000]
           ),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws, conn, uri.path || "/", []) do
      %{state | conn: conn, ref: ref, upgrade: %{}, heard: now()}
    else
      {:error, reason} -> retry(state, reason)
      {:error, conn, reason} -> retry(%{state | conn: conn}, reason)
    end
  end

  defp response({:status, ref, status}, %{ref: ref} = state),
    do: %{state | upgrade: Map.put(state.upgrade, :status, status)}

  defp response({:headers, ref, headers}, %{ref: ref} = state),
    do: %{state | upgrade: Map.put(state.upgrade, :headers, headers)}

  defp response({:done, ref}, %{ref: ref, websocket: nil} = state) do
    case Mint.WebSocket.new(
           state.conn,
           ref,
           state.upgrade[:status],
           state.upgrade[:headers] || []
         ) do
      {:ok, conn, websocket} ->
        state = %{state | conn: conn, websocket: websocket}

        push(state, %{
          "type" => "hello",
          "v" => Nunki.Join.version(),
          "device" => Store.device_id(),
          "key" => Store.key(state.tournament),
          "name" => Store.device_name(),
          "software" => Nunki.software()
        })

      {:error, conn, reason} ->
        Map.put(%{state | conn: conn}, :lost, {:upgrade, reason})
    end
  end

  defp response({:data, ref, data}, %{ref: ref, websocket: websocket} = state)
       when websocket != nil do
    case Mint.WebSocket.decode(websocket, data) do
      {:ok, websocket, frames} ->
        Enum.reduce(frames, %{state | websocket: websocket, heard: now()}, &frame/2)

      {:error, websocket, reason} ->
        Map.put(%{state | websocket: websocket}, :lost, reason)
    end
  end

  defp response(_other, state), do: state

  # What a frame decided (the line is gone, the tournament is gone) is acted
  # on once all of them are read.
  defp after_frames(%{removed: true} = state) do
    Logger.info("nunki: the server removed this device from a tournament; forgetting it")
    Countdown.cancel(state.tournament)
    Store.remove_tournament(state.tournament)
    send(self(), :stop)
    close(Map.delete(state, :removed)) |> Map.put(:stopping, true)
  end

  defp after_frames(%{lost: reason} = state), do: lost(Map.delete(state, :lost), reason)
  defp after_frames(state), do: state

  defp frame({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, %{"type" => _} = message} -> message(message, state)
      _bad -> state
    end
  end

  defp frame({:ping, data}, state), do: send_frame(state, {:pong, data})
  defp frame({:close, _code, _reason}, state), do: Map.put(state, :lost, :closed)
  defp frame(_other, state), do: state

  # --- the conversation --------------------------------------------------------

  defp message(%{"type" => "welcome"} = welcome, state) do
    Process.send_after(self(), :ping, @ping_ms)

    # The name may have changed in OpenPairings since the join.
    case welcome["tournament"] do
      %{"name" => name} when is_binary(name) ->
        Store.update_tournament(state.tournament, fn t ->
          put_in(t, ["tournament", "name"], name)
        end)

      _other ->
        :ok
    end

    Nunki.broadcast({:link, state.tournament})

    %{state | up?: true, error: nil, backoff: 1_000, status_sent: nil}
    |> send_status()
  end

  # The server's word on this device's name and room, and the rooms the
  # tournament has (`rooms_available`, names; an older server sends none,
  # and then the room is free text). Kept as it comes (cut to the server's
  # own 60 characters, should it ever send more). `"error": "room"` means
  # the room asked for was refused: the frame is the server's own state all
  # the same, and the page is told so it can say it.
  defp message(%{"type" => "settings"} = settings, state) do
    Store.update_tournament(state.tournament, fn t ->
      current = t["announcer"] || %{}

      announcer = %{
        "name" => text(settings["name"], current["name"]),
        "room" => text(settings["room"], current["room"])
      }

      announcer =
        case rooms_available(settings["rooms_available"]) do
          nil -> announcer
          names -> Map.put(announcer, "rooms_available", names)
        end

      put_in(t, ["announcer"], announcer)
    end)

    Nunki.broadcast({:link, state.tournament})
    if settings["error"] == "room", do: Nunki.broadcast({:room_refused, state.tournament})
    state
  end

  defp message(%{"type" => "round", "round" => %{} = payload}, state) do
    Announcer.round_received(state.tournament, payload)
    state
  end

  defp message(%{"type" => "countdown", "round" => round, "seconds_left" => seconds} = c, state)
       when is_integer(round) and is_integer(seconds) do
    Countdown.start(state.tournament, round, seconds, id: to_string(c["id"]), source: :server)
    state
  end

  defp message(%{"type" => "countdown_cancel"} = c, state) do
    Countdown.cancel(state.tournament, c["id"] && to_string(c["id"]))
    state
  end

  defp message(%{"type" => "read"} = read, state) do
    round = if is_integer(read["round"]), do: read["round"], else: nil
    Announcer.read(state.tournament, round)
    state
  end

  defp message(%{"type" => "announce"} = announce, state) do
    Announcer.announce(state.tournament, announce)
    state
  end

  defp message(%{"type" => "stop"}, state) do
    Speaker.stop()
    state
  end

  defp message(%{"type" => "leave"}, state), do: Map.put(state, :removed, true)

  defp message(%{"type" => "refused", "reason" => "revoked"}, state),
    do: Map.put(state, :removed, true)

  defp message(%{"type" => "refused", "reason" => reason}, state) do
    Nunki.broadcast({:link, state.tournament})

    Map.put(
      %{state | error: {:refused, to_string(reason)}, backoff: @refused_backoff_ms},
      :lost,
      :refused
    )
  end

  defp message(_other, state), do: state

  # --- status ------------------------------------------------------------------

  defp send_status(%{up?: true} = state) do
    status = status(state.tournament)

    if status == state.status_sent do
      state
    else
      %{push(state, Map.put(status, "type", "status")) | status_sent: status}
    end
  end

  defp send_status(state), do: state

  @doc false
  # What this device tells the server about itself: the voice that would
  # speak this tournament's language (nil when there is none), and whether
  # it is speaking right now.
  def status(tournament) do
    lang = Announcer.language(tournament)
    %{"voice" => Nunki.Voice.label(lang), "speaking" => Speaker.speaking?()}
  catch
    :exit, _reason -> %{"voice" => nil, "speaking" => false}
  end

  defp rooms_available(names) when is_list(names) do
    for name <- names, is_binary(name), do: String.slice(name, 0, 60)
  end

  defp rooms_available(_absent), do: nil

  defp text(value, _current) when is_binary(value), do: String.slice(value, 0, 60)
  defp text(_value, current), do: current || ""

  defp push(state, frame), do: send_frame(state, {:text, Jason.encode!(frame)})

  defp send_frame(%{websocket: nil} = state, _frame), do: state

  defp send_frame(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      %{state | websocket: websocket, conn: conn}
    else
      {:error, %Mint.WebSocket{} = websocket, reason} ->
        lost(%{state | websocket: websocket}, reason)

      {:error, conn, reason} ->
        lost(%{state | conn: conn}, reason)
    end
  end

  # --- losing it ---------------------------------------------------------------

  defp close(state) do
    if state.conn, do: Mint.HTTP.close(state.conn)
    %{state | conn: nil, websocket: nil, ref: nil, up?: false}
  end

  defp lost(%{stopping: true} = state, _reason), do: close(state)

  defp lost(state, reason) do
    if state.up?, do: Nunki.broadcast({:link, state.tournament})
    retry(close(state), reason)
  end

  defp retry(state, reason) do
    state = close(state)
    error = if reason == :refused, do: state.error, else: describe(reason)
    Process.send_after(self(), :connect, state.backoff)

    next =
      if state.backoff >= @refused_backoff_ms,
        do: 1_000,
        else: min(state.backoff * 2, @max_backoff_ms)

    if error != state.error, do: Nunki.broadcast({:link, state.tournament})
    %{state | error: error, backoff: next}
  end

  defp describe(%{reason: reason}), do: describe(reason)
  defp describe(:econnrefused), do: :nobody_answers
  defp describe(:nxdomain), do: :no_such_address
  defp describe(:timeout), do: :timeout
  defp describe(:closed), do: :closed
  defp describe(:silent), do: :silent
  defp describe({:upgrade, _}), do: :not_a_server
  defp describe(_other), do: :other

  defp now, do: System.monotonic_time(:millisecond)
end
