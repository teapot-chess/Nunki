defmodule Nunki.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    File.mkdir_p!(Nunki.Paths.data())
    tidy_release_tmp()

    opts = [strategy: :one_for_one, name: Nunki.Supervisor]
    Supervisor.start_link(children(), opts)
  end

  @doc """
  What Nunki runs. The store before everything that reads it, the speaker
  and the countdown before the lines that feed them, the endpoint last.

  A stop goes the other way round, and every child has a deadline: no
  supervisor waits `:infinity` for anything. The reaper is first so that
  it stops last, and takes with it any voice still talking.
  """
  def children do
    [
      Nunki.Cmd.Reaper,
      # The PIN (the box's request first) before anything that could serve a page.
      Nunki.AccessPin,
      Nunki.DoorGuard,
      bounded({Phoenix.PubSub, name: Nunki.PubSub}),
      bounded({Registry, keys: :unique, name: Nunki.LinkRegistry}),
      bounded({Task.Supervisor, name: Nunki.TaskSupervisor})
    ] ++
      fake_voice() ++
      [
        Nunki.Store,
        Nunki.Speaker,
        Nunki.Countdown,
        bounded({DynamicSupervisor, name: Nunki.Links, strategy: :one_for_one}),
        # Which voices this machine has: asked once, in the background, since
        # asking PowerShell takes a second or two and nobody should wait for it.
        Supervisor.child_spec({Task, &refresh_voices/0}, id: :voices),
        {Nunki.Updates.Checker, timer: Application.get_env(:nunki, :updates_timer, true)},
        Nunki.LauncherDetails
      ] ++
      if(Application.get_env(:nunki, :start_links, true),
        do: [Supervisor.child_spec({Task, &Nunki.Tournaments.start_links/0}, id: :links)],
        else: []
      ) ++
      [bounded(NunkiWeb.Endpoint, 8_000)]
  end

  # A supervisor's own default is to wait for its children forever.
  defp bounded(spec, ms \\ 5_000), do: Supervisor.child_spec(spec, shutdown: ms)

  # The fake voice keeps what it was told in an Agent; only when it is the voice.
  defp fake_voice do
    if Nunki.Voice.backend() == Nunki.Voice.Fake, do: [Nunki.Voice.Fake], else: []
  end

  defp refresh_voices do
    Nunki.Voice.refresh()
  end

  @impl true
  def config_change(changed, _new, removed) do
    NunkiWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # A release writes the configuration it starts with to a file in
  # RELEASE_TMP, a new one every start, and never takes one away. They hold
  # the cookie secret and they add up; the one this start is using stays.
  defp tidy_release_tmp do
    with tmp when is_binary(tmp) <- System.get_env("RELEASE_TMP"),
         mine when is_binary(mine) <- System.get_env("RELEASE_SYS_CONFIG") do
      for file <- Path.wildcard(Path.join(Path.expand(tmp), "nunki-*.runtime.config")),
          Path.basename(file, ".config") != Path.basename(mine) do
        File.rm(file)
      end
    end

    :ok
  end
end
