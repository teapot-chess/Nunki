defmodule Nunki.Speaker do
  @moduledoc """
  The mouth: a queue of utterances, said one at a time, each by one OS
  process (`Nunki.Voice.start/3`).

  `say/3` puts lines at the end of the queue; `stop/0` empties it and kills
  what is being said - the program and anything it started. A line that
  takes longer than a minute is taken for a voice that hung and is stopped
  the same way: no single board pairing takes a minute to read, and a stuck
  voice must not hold up the countdown's "the round starts now".

  Every change is broadcast (`{:speaker, status}` on `Nunki.topic/0`): the
  pages show the line being read, and the links tell the server whether
  Nunki is speaking.
  """

  use GenServer

  require Logger

  alias Nunki.Voice

  @longest_ms 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Queues `lines` to be said in `lang` (\"en\" or \"nl\"). `opts`:
  `:tournament` (whose lines they are, for the hall screen).
  """
  def say(lines, lang, opts \\ []) when is_list(lines) and lang in ["en", "nl"] do
    GenServer.cast(__MODULE__, {:say, lines, lang, Keyword.get(opts, :tournament)})
  end

  @doc "Stops speaking now, and forgets everything still queued."
  def stop, do: GenServer.call(__MODULE__, :stop)

  @doc "`%{speaking?, line, tournament, queued, error}`."
  def status, do: GenServer.call(__MODULE__, :status)

  def speaking? do
    status().speaking?
  catch
    :exit, _not_running -> false
  end

  # --- the process -----------------------------------------------------------------

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    Nunki.Voice.sweep()
    {:ok, %{queue: :queue.new(), current: nil, error: nil, timer: nil}}
  end

  @impl true
  def handle_cast({:say, lines, lang, tournament}, state) do
    queue =
      Enum.reduce(lines, state.queue, fn line, queue ->
        :queue.in(%{text: line, lang: lang, tournament: tournament}, queue)
      end)

    {:noreply, %{state | queue: queue} |> next() |> tell()}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    state = halt(%{state | queue: :queue.new()})
    {:reply, :ok, tell(state)}
  end

  def handle_call(:status, _from, state), do: {:reply, public(state), state}

  @impl true
  def handle_info(:too_long, %{current: {utterance, _handle}} = state) do
    Logger.warning("A line took longer than a minute to say; stopped: #{inspect(utterance.text)}")
    {:noreply, state |> halt() |> next() |> tell()}
  end

  def handle_info(:too_long, state), do: {:noreply, state}

  def handle_info(message, %{current: {_utterance, handle}} = state) do
    cond do
      Voice.done?(handle, message) ->
        Voice.finished(handle)
        if state.timer, do: Process.cancel_timer(state.timer)
        {:noreply, %{state | current: nil, timer: nil} |> next() |> tell()}

      true ->
        # What the program printed (an error, usually) is in the log at
        # debug; the exit status is what counts.
        with {_port, {:data, data}} <- message, do: Logger.debug("voice: #{data}")
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    halt(state)
    :ok
  end

  # --- the queue -------------------------------------------------------------------

  defp next(%{current: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, utterance}, queue} ->
        state = %{state | queue: queue}

        case Voice.start(utterance.text, utterance.lang) do
          {:ok, handle} ->
            timer = Process.send_after(self(), :too_long, @longest_ms)
            %{state | current: {utterance, handle}, timer: timer, error: nil}

          {:error, reason} ->
            Logger.warning("Nothing could be said: #{inspect(reason)}")
            # Whatever made this one fail will make the rest fail too, and a
            # queue of failures read out one by one in a log helps nobody.
            %{state | queue: :queue.new(), error: reason}
        end

      {:empty, _queue} ->
        state
    end
  end

  defp next(state), do: state

  defp halt(%{current: {_utterance, handle}} = state) do
    Voice.stop(handle)
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | current: nil, timer: nil}
  end

  defp halt(state), do: state

  defp public(state) do
    {line, tournament} =
      case state.current do
        {utterance, _handle} -> {utterance.text, utterance.tournament}
        nil -> {nil, nil}
      end

    %{
      speaking?: state.current != nil,
      line: line,
      tournament: tournament,
      queued: :queue.len(state.queue),
      error: state.error
    }
  end

  defp tell(state) do
    Nunki.broadcast({:speaker, public(state)})
    state
  end
end
