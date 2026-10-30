defmodule Nunki.Store do
  @moduledoc """
  Everything Nunki keeps, in one file: `<data>/state.json`, owned by this
  process and nobody else.

      {"version": 1,
       "device_id": "...", "device_name": "hall-pc",
       "tournaments": {"<local id>": {"id", "server", "socket", "key",
                                      "tournament": {"id", "name"},
                                      "announcer": {"name", "room", "rooms_available"},
                                      "round": <the last round payload>,
                                      "announced": 3, "joined_at": "..."}},
       "settings": {"language": "follow", "voices": {"nl": "..."},
                    "read_on_publish": true, "update_check": "ask"}}

  Written whole on every change, atomically: to `state.json.tmp`, made
  private (0600), then renamed over the old one. A machine that loses power
  mid-write has the old file or the new one, never half of each. It changes
  a few times a round; it can afford to be written whole.

  `"announcer"` is this device's name and room *in that tournament*, as the
  server last said them (`settings` frame), with `rooms_available`, the
  names of the tournament's rooms (absent from an older server, which has
  only free text). The server is the truth: the device asks for a change
  over the line and keeps what the server answers.

  The key of each tournament is in the file and nowhere else: `tournaments/0`
  and `tournament/1` leave it out, so a page cannot show what it was never
  given. Only the link asks for it (`key/1`).

  A file that is not JSON (somebody's editor, a disk that lied) is put
  aside as `state.json.broken-<time>` and Nunki starts as if new: a hall
  that has to join again is better than a program that does not start.
  """

  use GenServer

  require Logger

  @settings_defaults %{
    "language" => "follow",
    "voices" => %{},
    "read_on_publish" => true,
    "update_check" => "ask"
  }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  # --- the device ---------------------------------------------------------------

  @doc "This device's id: random, made on the first start, kept."
  def device_id, do: call(:device_id)

  @doc "What the server calls this device: the machine's name unless renamed."
  def device_name, do: call(:device_name)

  def put_device_name(name) when is_binary(name), do: call({:put_device_name, name})

  # --- tournaments --------------------------------------------------------------

  @doc "The joined tournaments, oldest first, without their keys."
  def tournaments, do: call(:tournaments)

  @doc "One joined tournament without its key, or nil."
  def tournament(id), do: call({:tournament, id})

  @doc "The link's key. For `Nunki.Link` and nothing else."
  def key(id), do: call({:key, id})

  @doc """
  Adds a joined tournament: `%{"server", "socket", "key", "tournament"}`.
  Joining the same tournament of the same server again replaces the old
  entry and keeps its local id. `{:ok, id}`.
  """
  def add_tournament(attrs), do: call({:add, attrs})

  def remove_tournament(id), do: call({:remove, id})

  @doc """
  Changes one tournament with `fun` (a map in, a map out). Nothing happens
  to a tournament that is not there. `{:ok, before, after}` or `:error`.
  """
  def update_tournament(id, fun), do: call({:update, id, fun})

  # --- settings -----------------------------------------------------------------

  def settings, do: call(:settings)

  def setting(key), do: Map.get(settings(), key)

  def put_setting(key, value) when is_binary(key), do: call({:put_setting, key, value})

  @doc "Starts again from the file on disk, or from nothing (tests)."
  def reload, do: call(:reload)

  defp call(message), do: GenServer.call(__MODULE__, message)

  # --- the process --------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.get_lazy(opts, :path, &Nunki.Paths.state_file/0)
    {:ok, %{path: path, data: Nunki.Store.Advanced.derive(load(path), path)}}
  end

  @impl true
  def handle_call(:device_id, _from, state), do: {:reply, state.data["device_id"], state}
  def handle_call(:device_name, _from, state), do: {:reply, state.data["device_name"], state}

  def handle_call({:put_device_name, name}, _from, state) do
    name = name |> String.trim() |> String.slice(0, 60)
    name = if name == "", do: hostname(), else: name
    {:reply, :ok, save(state, put_in(state.data["device_name"], name))}
  end

  def handle_call(:tournaments, _from, state) do
    list =
      state.data["tournaments"]
      |> Map.values()
      |> Enum.sort_by(&{&1["joined_at"], &1["id"]})
      |> Enum.map(&public/1)

    {:reply, list, state}
  end

  def handle_call({:tournament, id}, _from, state) do
    {:reply, state.data["tournaments"] |> Map.get(id) |> public(), state}
  end

  def handle_call({:key, id}, _from, state) do
    {:reply, get_in(state.data, ["tournaments", id, "key"]), state}
  end

  def handle_call({:add, attrs}, _from, state) do
    existing =
      Enum.find(Map.values(state.data["tournaments"]), fn t ->
        t["socket"] == attrs["socket"] and
          get_in(t, ["tournament", "id"]) == get_in(attrs, ["tournament", "id"])
      end)

    id = (existing && existing["id"]) || new_id()

    entry =
      Map.merge(
        %{
          "round" => nil,
          "announced" => 0,
          "joined_at" => DateTime.to_iso8601(DateTime.utc_now(:second))
        },
        existing || %{}
      )
      |> Map.merge(Map.take(attrs, ["server", "socket", "key", "tournament"]))
      |> Map.put("id", id)

    data = put_in(state.data, ["tournaments", id], entry)
    {:reply, {:ok, id}, save(state, data)}
  end

  def handle_call({:remove, id}, _from, state) do
    if Map.has_key?(state.data["tournaments"], id) do
      {_gone, tournaments} = Map.pop(state.data["tournaments"], id)
      {:reply, :ok, save(state, %{state.data | "tournaments" => tournaments})}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:update, id, fun}, _from, state) do
    case Map.fetch(state.data["tournaments"], id) do
      {:ok, before} ->
        changed = fun.(before) |> Map.put("id", id) |> Map.put("key", before["key"])

        if changed == before do
          {:reply, {:ok, public(before), public(changed)}, state}
        else
          data = put_in(state.data, ["tournaments", id], changed)
          {:reply, {:ok, public(before), public(changed)}, save(state, data)}
        end

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call(:settings, _from, state) do
    {:reply, Map.merge(@settings_defaults, state.data["settings"]), state}
  end

  def handle_call({:put_setting, key, value}, _from, state) do
    {:reply, :ok, save(state, put_in(state.data, ["settings", key], value))}
  end

  def handle_call(:reload, _from, state) do
    {:reply, :ok, %{state | data: Nunki.Store.Advanced.derive(load(state.path), state.path)}}
  end

  # --- the file -----------------------------------------------------------------

  defp public(nil), do: nil
  defp public(tournament), do: Map.delete(tournament, "key")

  defp load(path) do
    data =
      case File.read(path) do
        {:ok, text} ->
          case Jason.decode(text) do
            {:ok, %{} = data} ->
              data

            _broken ->
              aside = "#{path}.broken-#{System.os_time(:second)}"
              File.rename(path, aside)
              Logger.warning("state.json could not be read; it was put aside as #{aside}")
              %{}
          end

        {:error, _none} ->
          %{}
      end

    fresh? = not Map.has_key?(data, "device_id")

    data =
      %{
        "version" => 1,
        "device_id" => data["device_id"] || new_device_id(),
        "device_name" => data["device_name"] || hostname(),
        "tournaments" => data["tournaments"] || %{},
        "settings" => data["settings"] || %{}
      }

    # The first start writes the file at once: the device id must not change
    # between a join and the next start, and the release check in CI looks
    # for the file.
    if fresh?, do: write(path, data)
    data
  end

  defp save(state, data) do
    if data != state.data do
      write(state.path, data)
      Nunki.broadcast(:state_changed)
    end

    %{state | data: data}
  end

  def write(path, data) do
    tmp = path <> ".tmp"
    File.mkdir_p!(Path.dirname(path))

    # Empty and private first, the contents after: there is no moment at
    # which the keys sit in a file somebody else may read. On Windows chmod
    # does next to nothing and the profile folder's own rights do the job.
    with :ok <- File.write(tmp, ""),
         _ <- File.chmod(tmp, 0o600),
         :ok <- File.write(tmp, Jason.encode_to_iodata!(data, pretty: true)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        Logger.error("state.json could not be written: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp new_device_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  defp new_id, do: 6 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end
end
