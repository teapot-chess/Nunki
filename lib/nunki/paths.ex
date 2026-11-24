defmodule Nunki.Paths do
  @moduledoc """
  Where Nunki keeps things. One directory (`config :nunki, :data_dir`,
  `NUNKI_DATA`) holds `state.json`, the cookie secret, the launcher's token
  file, the updater's request and, for the seconds it takes to say them,
  the texts the speech engine reads; `Nunki.DataHome` says where that is on
  an installed copy.
  """

  def data, do: ensure(Application.fetch_env!(:nunki, :data_dir))

  @doc "The state file: `<data>/state.json`."
  def state_file, do: Path.join(data(), "state.json")

  @doc """
  Where the text of an utterance waits for the speech engine to read it:
  `<data>/speech`. Not the system's temp folder - the Linux service has a
  private one, which is fine, and a Windows profile's is cleaned by tools
  that do not ask, which is not.
  """
  def speech_dir, do: ensure(Path.join(data(), "speech"))

  # sobelow_skip ["Traversal.FileModule"]
  defp ensure(dir) do
    File.mkdir_p!(dir)
    dir
  end
end
