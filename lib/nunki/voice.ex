defmodule Nunki.Voice do
  @moduledoc """
  The machine's own voice: what Nunki speaks with, and the one place that
  starts and stops it.

  Speech is the operating system's, spoken by this process, and not the
  browser's. Chromium's `speechSynthesis.speak()` needs a click on the page
  after every load, so a hall machine that restarts, reloads or updates
  itself is silent until somebody walks up to it; a tab in the background
  is throttled; and the hall screen may be on a projector, or not open at
  all. A process that runs a program needs nothing from any browser. The
  price is that the voices are whatever the system has (README, "Voices").

  ## Backends

  One module per system, chosen by `:os.type()` unless
  `config :nunki, :voice_backend` names one:

    * `Nunki.Voice.Windows` - Windows PowerShell 5.1 running
      `priv/voice/windows.ps1`: WinRT's speech synthesiser (the OneCore
      voices, where the Dutch speech pack puts its voice), SAPI when WinRT
      is not there.
    * `Nunki.Voice.MacOS` - `say`.
    * `Nunki.Voice.Linux` - `espeak-ng`, or `spd-say` when that is all
      there is.
    * `Nunki.Voice.Fake` - writes down what it was asked to say and makes no
      sound. Development and the tests.

  A backend builds commands; it never runs one itself. What it needs from
  the system - running a program, finding one, whether a file is there - is
  an `env` map handed in (`default_env/0`), so the tests build every command
  and parse every voice list without a single real program running.

  The text never goes on a command line: it is written to a file in
  `Nunki.Paths.speech_dir/0` and the command is told the file's name.
  """

  require Logger

  @typedoc "A voice: `id` is what the backend is told, `label` what a person reads."
  @type voice :: %{id: String.t(), label: String.t(), lang: String.t()}

  @typedoc """
  What a backend may ask of the system: `cmd` (as `System.cmd/3`; the real
  one is `Nunki.Cmd.run/3`, which adds a deadline), `find`
  (as `System.find_executable/1`), `exists?` (as `File.exists?/1`), `env`
  (as `System.get_env/1`).
  """
  @type env :: %{cmd: fun(), find: fun(), exists?: fun(), env: fun()}

  @doc "A short name for the engine: \"Windows\", \"say\", \"espeak-ng\"."
  @callback engine(env) :: String.t() | nil

  @doc "The voices the system has, or `{:error, reason}` when it has no engine."
  @callback voices(env) :: {:ok, [voice]} | {:error, term}

  @doc """
  The program and arguments that read `text_file` aloud with `voice` (an
  id from `voices/1`, or nil for the engine's own choice) in `lang`
  (\"en\" or \"nl\"), and return when done.
  """
  @callback command(text_file :: String.t(), voice :: String.t() | nil, lang :: String.t(), env) ::
              {:ok, {String.t(), [String.t()]}} | {:error, term}

  @cache {__MODULE__, :voices}

  # --- choosing ---------------------------------------------------------------------

  @doc "The backend in use."
  def backend do
    case Application.get_env(:nunki, :voice_backend) do
      nil -> for_os(:os.type())
      module -> module
    end
  end

  @doc false
  def for_os({:win32, _}), do: Nunki.Voice.Windows
  def for_os({:unix, :darwin}), do: Nunki.Voice.MacOS
  def for_os(_unix), do: Nunki.Voice.Linux

  @doc "What a backend may ask of the real system."
  def default_env do
    %{
      # With a deadline, and killed if whoever asked is gone (Nunki.Cmd).
      cmd: &Nunki.Cmd.run/3,
      find: &System.find_executable/1,
      exists?: &File.exists?/1,
      env: &System.get_env/1
    }
  end

  # --- the voices -------------------------------------------------------------------

  @doc """
  The voices, as last asked. Asking takes a second or two on Windows (a
  PowerShell start), so it is done once at start and on the control page's
  Refresh, never on the way to saying something.
  """
  def list, do: :persistent_term.get(@cache, [])

  @doc "Asks the system for its voices again. `{:ok, voices}` or `{:error, reason}`."
  def refresh(backend \\ backend(), env \\ default_env()) do
    result =
      try do
        backend.voices(env)
      rescue
        error -> {:error, Exception.message(error)}
      end

    case result do
      {:ok, voices} ->
        :persistent_term.put(@cache, voices)
        Nunki.broadcast(:voices_changed)
        {:ok, voices}

      {:error, reason} ->
        Logger.info("No voices: #{inspect(reason)}")
        :persistent_term.put(@cache, [])
        Nunki.broadcast(:voices_changed)
        {:error, reason}
    end
  end

  @doc "The voices that speak `lang` (\"en\", \"nl\"), best match first."
  def for_language(voices \\ list(), lang) do
    Enum.filter(voices, &(language_of(&1.lang) == lang))
  end

  @doc """
  The voice to say something in `lang` with: the one chosen on the control
  page while the system still has it, else the first the system has for
  that language, else nil (the engine's own choice, which may well be
  English reading Dutch: the control page says so).
  """
  def resolve(lang, voices \\ list(), chosen \\ chosen_voices()) do
    matching = for_language(voices, lang)

    case Map.get(chosen, lang) do
      id when is_binary(id) and id != "" ->
        Enum.find(matching, &(&1.id == id)) || List.first(matching)

      _none ->
        List.first(matching)
    end
  end

  defp chosen_voices do
    case Nunki.Store.setting("voices") do
      %{} = map -> map
      _other -> %{}
    end
  catch
    :exit, _not_started -> %{}
  end

  @doc "What the status line says about the voice for `lang`: a label, or nil."
  def label(lang) do
    case resolve(lang) do
      %{label: label} -> label
      nil -> nil
    end
  end

  @doc "\"en\" for en-GB, en_US, english...; \"nl\" for nl-NL, nl_BE, ...; else the first two letters."
  def language_of(code) when is_binary(code) do
    code |> String.downcase() |> String.slice(0, 2)
  end

  def language_of(_other), do: nil

  @doc "The engine's name, or nil when this system has none."
  def engine(backend \\ backend(), env \\ default_env()), do: backend.engine(env)

  # --- speaking ---------------------------------------------------------------------

  @doc """
  Starts saying `text`. The owner (the calling process) is told
  `{:voice_done, ref}` when it is done, whichever way it ended.
  `{:ok, handle}` or `{:error, reason}`.
  """
  def start(text, lang, backend \\ backend()) do
    voice = resolve(lang)
    voice_id = voice && voice.id

    if Code.ensure_loaded?(backend) and function_exported?(backend, :start, 4) do
      backend.start(text, voice_id, lang, self())
    else
      start_command(backend, text, voice_id, lang)
    end
  end

  defp start_command(backend, text, voice_id, lang) do
    file = Path.join(Nunki.Paths.speech_dir(), "say-#{System.unique_integer([:positive])}.txt")
    File.write!(file, text)

    case backend.command(file, voice_id, lang, default_env()) do
      {:ok, {exe, args}} ->
        port =
          Port.open({:spawn_executable, exe}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :hide,
            args: args
          ])

        {:os_pid, os_pid} = Port.info(port, :os_pid)
        # Should the Speaker go without saying goodbye (killed, crashed),
        # the reaper sees to it that the voice goes too.
        Nunki.Cmd.Reaper.watch(os_pid)
        {:ok, %{ref: make_ref(), port: port, os_pid: os_pid, file: file}}

      {:error, reason} ->
        File.rm(file)
        {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc """
  Whether `message` says the utterance of `handle` has ended: the program's
  exit, or the fake's word for it.
  """
  def done?(%{port: port}, {port, {:exit_status, _status}}), do: true
  def done?(%{ref: ref}, {:voice_done, ref}), do: true
  def done?(_handle, _message), do: false

  @doc "Cleans up after an utterance that ended by itself."
  def finished(%{file: file} = handle) do
    if os_pid = handle[:os_pid], do: Nunki.Cmd.Reaper.unwatch(os_pid)
    File.rm(file)
    # Windows renders the reading to a .wav beside the text, and removes it
    # itself - unless Stop killed PowerShell first.
    File.rm(Path.rootname(file) <> ".wav")
  end

  def finished(_handle), do: :ok

  @doc "Removes what earlier readings left in the speech folder (at start-up, when none can be running)."
  def sweep do
    for file <- Path.wildcard(Path.join(Nunki.Paths.speech_dir(), "say-*")), do: File.rm(file)
    :ok
  end

  @doc """
  Stops an utterance now. The program and anything it started are killed:
  `taskkill /T /F` on Windows (PowerShell plays the sound in its own
  process, so the tree has to go), `kill` elsewhere.
  """
  def stop(handle, run \\ &Nunki.Cmd.run/3)

  def stop(%{port: port, os_pid: os_pid} = handle, run) do
    kill(os_pid, :os.type(), run)
    if Port.info(port), do: Port.close(port)
    finished(handle)
    :ok
  catch
    _kind, _reason -> :ok
  end

  def stop(%{fake: true} = handle, _run), do: Nunki.Voice.Fake.stop(handle)
  def stop(_handle, _run), do: :ok

  @doc false
  def kill(os_pid, {:win32, _}, run),
    do:
      run.("taskkill", ["/T", "/F", "/PID", Integer.to_string(os_pid)],
        stderr_to_stdout: true,
        timeout: 5_000
      )

  def kill(os_pid, _unix, run),
    do: run.("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true, timeout: 5_000)
end
