defmodule Nunki.Countdown do
  @moduledoc """
  The countdowns to the start of a round, one per joined tournament.

  Started by the server (`countdown`: a round, the seconds left and an id)
  or from the control page (1, 2, 5, 10, 15, 20 or 30 minutes, for the last round
  received); cancelled by the server (`countdown_cancel` with that id) or
  from the control page. A `countdown` with the id of the one running is a
  restatement - the server says it again after every reconnect - and only
  moves the end to where the server says it is; what was already announced
  is not announced again.

  The end is kept on this machine's monotonic clock (`Nunki.Clock`):
  `seconds_left` from the server, added to now. Nobody's wall clock is
  involved, so nobody's wall clock can be wrong.

  ## What is said

  Ten minutes before, five, one, and at zero - only those still ahead when
  the countdown starts (one that starts at exactly five minutes says the
  five at once). When the clock has jumped past several at once (a machine
  that slept), only the last of them is said: \"five minutes\" followed
  by \"one minute\" in the same breath helps nobody.

  At zero the countdown stays, as \"started\", for ten minutes, so the
  hall screen can say \"Round 3 has started\" to whoever comes in late;
  then it goes.

  Every change is broadcast as `{:countdown, tournament_id}` on
  `Nunki.topic/0`.
  """

  use GenServer

  alias Nunki.Clock

  @milestones [ten: 600, five: 300, one: 60, zero: 0]
  @linger_ms 10 * 60_000

  @doc "The minutes the control page offers."
  def local_choices, do: [1, 2, 5, 10, 15, 20, 30]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Starts (or restates) a countdown for a tournament. `opts`: `:id` (the
  server's; the control page's are made here) and `:source` (`:server`,
  `:local`).
  """
  def start(tournament, round, seconds_left, opts \\ [])
      when is_integer(round) and is_integer(seconds_left) do
    GenServer.call(__MODULE__, {:start, tournament, round, max(seconds_left, 0), opts})
  end

  @doc "Cancels the tournament's countdown; with an id, only when it is that one."
  def cancel(tournament, id \\ nil), do: GenServer.call(__MODULE__, {:cancel, tournament, id})

  @doc """
  The tournament's countdown, or nil: `%{round, id, source, remaining_ms,
  started?}`.
  """
  def get(tournament), do: GenServer.call(__MODULE__, {:get, tournament})

  @doc "Every countdown, by tournament."
  def all, do: GenServer.call(__MODULE__, :all)

  @doc "Whether any countdown has not reached zero yet."
  def running? do
    all() |> Map.values() |> Enum.any?(&(not &1.started?))
  catch
    :exit, _not_running -> false
  end

  @doc "Looks at the clock now (the timer does this by itself; the tests ask)."
  def tick, do: GenServer.call(__MODULE__, :tick)

  # --- the process ---------------------------------------------------------------

  @impl true
  def init(_opts), do: {:ok, %{countdowns: %{}, timer: nil}}

  @impl true
  def handle_call({:start, tournament, round, seconds, opts}, _from, state) do
    now = Clock.now_ms()

    id =
      Keyword.get(opts, :id) || "local-" <> Integer.to_string(System.unique_integer([:positive]))

    ends_at = now + seconds * 1000

    countdown =
      case Map.get(state.countdowns, tournament) do
        %{id: ^id, started_at: nil} = running ->
          %{running | ends_at: ends_at, round: round}

        # Restated after zero (a reconnect just after the start): the round
        # has started, and saying so twice is how a hall learns to ignore it.
        %{id: ^id} = started ->
          started

        _new_or_other ->
          %{
            tournament: tournament,
            round: round,
            id: id,
            source: Keyword.get(opts, :source, :server),
            ends_at: ends_at,
            started_at: nil,
            pending: for({which, s} <- @milestones, s <= seconds, do: {which, s})
          }
      end

    state = put_in(state.countdowns[tournament], countdown)
    changed(tournament)
    {:reply, {:ok, id}, state |> evaluate(now) |> schedule(now)}
  end

  def handle_call({:cancel, tournament, id}, _from, state) do
    case Map.get(state.countdowns, tournament) do
      %{id: running} when id == nil or id == running ->
        changed(tournament)
        state = %{state | countdowns: Map.delete(state.countdowns, tournament)}
        {:reply, :ok, schedule(state, Clock.now_ms())}

      _other ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:get, tournament}, _from, state) do
    {:reply, view(Map.get(state.countdowns, tournament), Clock.now_ms()), state}
  end

  def handle_call(:all, _from, state) do
    now = Clock.now_ms()
    {:reply, Map.new(state.countdowns, fn {t, c} -> {t, view(c, now)} end), state}
  end

  def handle_call(:tick, _from, state) do
    now = Clock.now_ms()
    {:reply, :ok, state |> evaluate(now) |> schedule(now)}
  end

  @impl true
  def handle_info(:tick, state) do
    now = Clock.now_ms()
    {:noreply, %{state | timer: nil} |> evaluate(now) |> schedule(now)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- the clock -----------------------------------------------------------------

  defp evaluate(state, now) do
    countdowns =
      state.countdowns
      |> Enum.map(fn {tournament, countdown} -> {tournament, due(countdown, now)} end)
      |> Enum.reject(fn {tournament, countdown} ->
        gone? = countdown.started_at != nil and now - countdown.started_at >= @linger_ms
        if gone?, do: changed(tournament)
        gone?
      end)
      |> Map.new()

    %{state | countdowns: countdowns}
  end

  defp due(countdown, now) do
    {passed, ahead} =
      Enum.split_with(countdown.pending, fn {_which, s} -> countdown.ends_at - s * 1000 <= now end)

    case List.last(passed) do
      nil ->
        countdown

      {which, _s} ->
        Nunki.Announcer.milestone(countdown.tournament, which, countdown.round)
        changed(countdown.tournament)
        started_at = if which == :zero, do: now, else: countdown.started_at
        %{countdown | pending: ahead, started_at: started_at}
    end
  end

  # One timer, for whatever comes first: a milestone, or a started
  # countdown's time to go.
  defp schedule(state, now) do
    if state.timer, do: Process.cancel_timer(state.timer)

    moments =
      Enum.flat_map(Map.values(state.countdowns), fn countdown ->
        Enum.map(countdown.pending, fn {_which, s} -> countdown.ends_at - s * 1000 end) ++
          if(countdown.started_at, do: [countdown.started_at + @linger_ms], else: [])
      end)

    case moments do
      [] ->
        %{state | timer: nil}

      _ ->
        delay = max(Enum.min(moments) - now, 0)
        %{state | timer: Process.send_after(self(), :tick, delay)}
    end
  end

  defp view(nil, _now), do: nil

  defp view(countdown, now) do
    %{
      round: countdown.round,
      id: countdown.id,
      source: countdown.source,
      remaining_ms: max(countdown.ends_at - now, 0),
      started?: countdown.started_at != nil
    }
  end

  defp changed(tournament), do: Nunki.broadcast({:countdown, tournament})
end
