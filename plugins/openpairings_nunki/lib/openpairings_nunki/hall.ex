defmodule OpenPairingsNunki.Hall do
  @moduledoc """
  The plugin's context: join codes, announcers, the round countdown, and
  the commands the tournament page sends.

  Nothing here runs on its own. An announcer's WebSocket handler
  (`OpenPairingsNunkiWeb.LinkSocket`) is the only process the plugin has,
  one per connected announcer, and everything that has to reach it goes
  over the plugin's own PubSub topic, `"nunki:tournament:<id>"`:

    * `{:nunki_send, frame}` - push this frame to every announcer of the
      tournament (countdown, countdown_cancel, read, stop).
    * `{:nunki_revoked, announcer_id}` - that announcer was removed; its
      socket says `leave` and hangs up.
    * `{:nunki_superseded, announcer_id, pid}` - the same announcer
      connected again; the older socket is the stale one.
    * `{:nunki_settings_changed, announcer_id}` - that announcer's name or
      room changed (on the page or from the device); its socket reloads
      the row and tells the device.
    * `{:nunki_changed, tournament_id}` - something the page shows changed
      (an announcer connected, reported, left; a countdown started).

  Page-facing functions take the viewer's scope first and check the
  tournament against it, so a crafted event cannot reach somebody else's
  hall.
  """
  import Ecto.Query

  alias OpenPairingsNunki.{Announcer, Countdown, JoinCode, Protocol}
  alias OpenPairingsNunki.Plugin
  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngine.{Features, Repo, Rooms, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  # hall-link-v1, "Pairing a device": 32 random bytes, base64url, the same
  # code every hall app is paired with. Nobody types it, so it need not be
  # short; it travels in a link, pasted or scanned.
  @code_bytes 32
  @code_ttl_seconds 15 * 60
  @online_seconds 90
  @countdown_minutes [1, 2, 5, 10, 15]
  @name_max 60

  @doc "The minutes a countdown may run for, as the page offers them."
  def countdown_minutes, do: @countdown_minutes

  @doc "The default countdown, in minutes."
  def default_countdown_minutes, do: 5

  ## ---------- topics ----------

  @doc "The plugin's own topic for one tournament."
  def topic(tournament_id), do: "nunki:tournament:#{tournament_id}"

  @doc "Subscribes the calling process to `topic/1`."
  def subscribe(tournament_id),
    do: Phoenix.PubSub.subscribe(PairingsEngine.PubSub, topic(tournament_id))

  defp broadcast(tournament_id, message),
    do: Phoenix.PubSub.broadcast(PairingsEngine.PubSub, topic(tournament_id), message)

  @doc "Tells the tournament's pages to look again."
  def notify(tournament_id), do: broadcast(tournament_id, {:nunki_changed, tournament_id})

  ## ---------- the server ----------

  @doc "This server as the announcer shows it: the endpoint's host."
  def server_name, do: URI.parse(PairingsEngineWeb.Endpoint.url()).host || ""

  @doc "The absolute path of the link announcers dial."
  def socket_path, do: PairingsEngineWeb.Endpoint.path("/p/nunki/link")

  @doc "The join link for `code`."
  def join_url(code),
    do:
      PairingsEngineWeb.Endpoint.url() <> PairingsEngineWeb.Endpoint.path("/p/nunki/join/#{code}")

  ## ---------- join codes ----------

  @doc """
  A new join code for `tournament`: `{:ok, %{code, url, expires_at}}`. The
  code is shown to the arbiter once and kept here only as its hash.
  """
  def create_join_code(%Scope{} = scope, %Tournament{} = tournament) do
    tournament = authorize!(scope, tournament)
    code = random_code()
    now = now()
    expires_at = DateTime.add(now, @code_ttl_seconds)

    {:ok, _row} =
      Repo.insert(%JoinCode{
        tournament_id: tournament.id,
        code_hash: sha256(code),
        expires_at: expires_at,
        created_by_id: scope.user.id
      })

    {:ok, %{code: code, url: join_url(code), expires_at: expires_at}}
  end

  @doc """
  Spends a join code and joins the device to its tournament.

  `attrs` holds `"device"`, `"name"` and `"software"` as the device sent
  them. Answers `{:ok, %{announcer, key, tournament}}` - `key` the one copy
  of the device's secret there will ever be - or `{:error, reason}` with
  `:not_found` (no such code, or its tournament is gone), `:used` or
  `:expired` - which a code made before the account's announcer was
  switched off also is.

  The same device joining the same tournament again (it was removed, or
  forgot the key) gets its row back with a new key, not a second row.
  """
  def redeem_join_code(code, %{"device" => device} = attrs)
      when is_binary(code) and is_binary(device) do
    now = now()

    Repo.transaction(fn ->
      with %JoinCode{} = jc <- find_code(code) || {:error, :not_found},
           :ok <- usable(jc, now),
           %Tournament{} = t <-
             Tournaments.get_tournament(jc.tournament_id) || {:error, :not_found},
           :ok <- if(feature_on?(t), do: :ok, else: {:error, :expired}),
           :ok <- spend(jc, now) do
        key = random_key()
        announcer = register(t, attrs, key, now)
        notify(t.id)
        %{announcer: announcer, key: key, tournament: t}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # The code as it was given (base64url is case-sensitive); failing that,
  # lowercased, for a 16-character base32 code made before the codes grew,
  # which was case-blind and still lives out its fifteen minutes.
  defp find_code(code) do
    Repo.get_by(JoinCode, code_hash: sha256(code)) ||
      if(String.downcase(code) != code,
        do: Repo.get_by(JoinCode, code_hash: sha256(String.downcase(code)))
      )
  end

  defp usable(%JoinCode{used_at: %DateTime{}}, _now), do: {:error, :used}

  defp usable(%JoinCode{expires_at: at}, now) do
    if DateTime.compare(at, now) == :gt, do: :ok, else: {:error, :expired}
  end

  # Conditional on still being unused, so two devices racing for one code
  # do not both win it.
  defp spend(jc, now) do
    case Repo.update_all(
           from(j in JoinCode, where: j.id == ^jc.id and is_nil(j.used_at)),
           set: [used_at: now]
         ) do
      {1, _} -> :ok
      _ -> {:error, :used}
    end
  end

  defp register(t, attrs, key, now) do
    fields = %{
      name: clip(attrs["name"], @name_max),
      software: clip(attrs["software"], 100),
      key_hash: sha256(key),
      status: %{},
      connected: false,
      revoked_at: nil,
      updated_at: now
    }

    device = clip(attrs["device"], 100)

    case Repo.get_by(Announcer, tournament_id: t.id, device_id: device) do
      nil ->
        Repo.insert!(
          struct(Announcer, Map.merge(fields, %{tournament_id: t.id, device_id: device}))
        )

      existing ->
        existing |> Ecto.Changeset.change(fields) |> Repo.update!()
    end
  end

  ## ---------- announcers ----------

  @doc "The announcers of `tournament` that have not been removed, by name."
  def list_announcers(%Scope{} = scope, %Tournament{} = tournament) do
    tournament = authorize!(scope, tournament)

    Repo.all(
      from a in Announcer,
        where: a.tournament_id == ^tournament.id and is_nil(a.revoked_at),
        order_by: [asc: a.name, asc: a.id]
    )
  end

  @doc "Every announcer of every tournament `scope`'s user may open, tournament preloaded."
  def list_for_account(%Scope{} = scope) do
    Repo.all(
      from a in Announcer,
        where:
          is_nil(a.revoked_at) and
            a.tournament_id in subquery(Tournaments.authorized_tournament_ids(scope)),
        order_by: [desc: a.tournament_id, asc: a.name],
        preload: [:tournament]
    )
  end

  @doc """
  The announcer `device_id` whose key is `key`: `{:ok, announcer}`, or
  `{:error, :key}` for no such pair, `{:error, :revoked}` for one removed
  in OpenPairings (or whose tournament is gone, or whose account has
  switched the announcer off: the switch is access, not just a menu entry).
  The hash is compared in constant time against every row the device has.
  """
  def authenticate(device_id, key) when is_binary(device_id) and is_binary(key) do
    hash = sha256(key)

    Repo.all(from a in Announcer, where: a.device_id == ^device_id)
    |> Enum.find(&Plug.Crypto.secure_compare(&1.key_hash, hash))
    |> case do
      nil ->
        {:error, :key}

      %Announcer{revoked_at: %DateTime{}} ->
        {:error, :revoked}

      %Announcer{} = a ->
        case Tournaments.get_tournament(a.tournament_id) do
          %Tournament{} = t -> if feature_on?(t), do: {:ok, a}, else: {:error, :revoked}
          nil -> {:error, :revoked}
        end
    end
  end

  def authenticate(_device_id, _key), do: {:error, :key}

  # Whether the account that owns `tournament` has the announcer switched on.
  # Asked at every join and every hello: an announcer is a way to receive the
  # tournament's rounds, so turning the feature off has to cut it off.
  defp feature_on?(%Tournament{user_id: user_id}) do
    user = user_id && Repo.get(User, user_id)
    Features.enabled?(user, Plugin.feature())
  end

  @doc "The announcer row with `id`, or nil (gone, or never was)."
  def get_announcer(id), do: Repo.get(Announcer, id)

  @doc """
  The arbiter renames an announcer or sets its room from the tournament
  page. `attrs` holds `"name"` and/or `"room_id"`; an absent key stays as
  it is. `{:ok, announcer}`, `{:error, :room}` for a room the tournament
  does not have, or `{:error, :not_found}` for an announcer that is not (or
  no longer) this tournament's. See `apply_settings/2` for the rules.
  """
  def update_settings(%Scope{} = scope, %Tournament{} = tournament, announcer_id, attrs) do
    tournament = authorize!(scope, tournament)

    case Repo.get_by(Announcer, id: announcer_id, tournament_id: tournament.id) do
      %Announcer{revoked_at: nil} = a -> apply_settings(a, attrs)
      _gone -> {:error, :not_found}
    end
  end

  @doc """
  The room `announcer` stands in: the tournament's room its `room_id` still
  points at, as `PairingsEngine.Rooms` lists it, or nil. A room that was
  deleted is no room; a rename shows, because the id is what is kept.
  """
  def effective_room(%Tournament{} = tournament, %Announcer{room_id: id}),
    do: Rooms.get(tournament, id)

  @doc """
  The room as the device is told: the effective room's current name, or,
  for an announcer from before rooms (no `room_id`), the free text it
  still carries, which is a label and nothing more.
  """
  def room_label(%Tournament{} = tournament, %Announcer{} = a) do
    case effective_room(tournament, a) do
      %{name: name} -> name
      nil -> if a.room_id == "", do: a.room, else: ""
    end
  end

  @doc """
  Stores a name and/or room for `announcer` and, when that changed
  anything, tells the tournament's pages and the announcer's own socket.
  This is the one door for both sides: the server is the truth, so what
  the device asks for is only ever a request.

  The room is a room of the tournament, asked for by `"room_id"` (the
  page) or by `"room"`, its name (the device; trimmed, case-insensitive).
  An empty one clears it. The exact free text an older announcer still
  carries is accepted back unchanged; anything else is refused with
  `{:error, :room}` and nothing at all is stored. The name is trimmed and
  cut to 60 characters; an absent key stays as it is, and so does the name
  when the new one comes out empty. `{:ok, announcer}` as stored.
  """
  def apply_settings(%Announcer{} = a, attrs) when is_map(attrs) do
    name = if is_binary(attrs["name"]), do: clip(attrs["name"], @name_max), else: ""

    with %Tournament{} = t <- Tournaments.get_tournament(a.tournament_id) || {:error, :gone},
         {:ok, room_changes} <- room_changes(t, a, attrs) do
      changes =
        %{name: if(name == "", do: a.name, else: name)}
        |> Map.merge(room_changes)
        |> Enum.reject(fn {key, value} -> Map.fetch!(a, key) == value end)

      if changes == [] do
        {:ok, a}
      else
        Repo.update_all(from(x in Announcer, where: x.id == ^a.id), set: changes)
        broadcast(a.tournament_id, {:nunki_settings_changed, a.id})
        notify(a.tournament_id)
        {:ok, struct(a, changes)}
      end
    else
      {:error, :gone} -> {:error, :not_found}
      {:error, :room} -> {:error, :room}
    end
  end

  def apply_settings(%Announcer{} = a, _attrs), do: {:ok, a}

  defp room_changes(t, a, %{"room_id" => id}) when is_binary(id) do
    id = String.trim(id)

    case {id, Rooms.get(t, id)} do
      {"", _} -> {:ok, %{room_id: "", room: ""}}
      {_, %{} = room} -> {:ok, %{room_id: room.id, room: room.name}}
      {same, nil} when same == a.room_id -> {:ok, %{}}
      _unknown -> {:error, :room}
    end
  end

  defp room_changes(t, a, %{"room" => text}) when is_binary(text) do
    text = clip(text, @name_max)

    case {text, Rooms.find_by_name(t, text)} do
      {"", _} -> {:ok, %{room_id: "", room: ""}}
      {_, %{} = room} -> {:ok, %{room_id: room.id, room: room.name}}
      {same, nil} when same == a.room and a.room_id == "" -> {:ok, %{}}
      _unknown -> {:error, :room}
    end
  end

  defp room_changes(_t, _a, _attrs), do: {:ok, %{}}

  @doc "Marks the announcer connected, seen now."
  def connected(%Announcer{} = a), do: update_live(a, connected: true, last_seen_at: now())

  @doc "Marks the announcer seen now."
  def touch(%Announcer{} = a), do: update_live(a, last_seen_at: now())

  @doc "Marks the announcer's link down."
  def disconnected(%Announcer{} = a), do: update_live(a, connected: false, last_seen_at: now())

  @doc """
  Keeps what the device reported in `status`: at most eight keys, strings
  of a sensible length, scalar values. A device is trusted with its own
  voice's name, not with the database.
  """
  def put_status(%Announcer{} = a, status) when is_map(status) do
    clean =
      status
      |> Enum.filter(fn {k, v} -> is_binary(k) and byte_size(k) <= 32 and scalar?(v) end)
      |> Enum.take(8)
      |> Map.new(fn {k, v} -> {k, if(is_binary(v), do: clip(v, 120), else: v)} end)

    update_live(a, status: clean, last_seen_at: now())
  end

  def put_status(%Announcer{} = a, _status), do: touch(a)

  defp scalar?(v), do: is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v)

  defp update_live(%Announcer{} = a, changes) do
    Repo.update_all(from(x in Announcer, where: x.id == ^a.id), set: changes)
    notify(a.tournament_id)
    struct(a, changes)
  end

  @doc "Whether the announcer is online: a live link that was heard within 90 seconds."
  def online?(announcer, now \\ now())

  def online?(%Announcer{connected: true, last_seen_at: %DateTime{} = at}, now),
    do: DateTime.diff(now, at) <= @online_seconds

  def online?(_announcer, _now), do: false

  @doc """
  Removes an announcer from `tournament`. A connected one is told `leave`
  at once; one that is not is told `refused revoked` when it next calls.
  """
  def revoke(%Scope{} = scope, %Tournament{} = tournament, announcer_id) do
    tournament = authorize!(scope, tournament)

    case Repo.get_by(Announcer, id: announcer_id, tournament_id: tournament.id) do
      nil ->
        {:error, :not_found}

      a ->
        a |> Ecto.Changeset.change(revoked_at: now(), connected: false) |> Repo.update!()
        broadcast(tournament.id, {:nunki_revoked, a.id})
        notify(tournament.id)
        :ok
    end
  end

  @doc "The device removed the tournament on its side (`leave`): the row goes."
  def forget(%Announcer{} = a) do
    Repo.delete_all(from x in Announcer, where: x.id == ^a.id)
    notify(a.tournament_id)
    :ok
  end

  @doc "Tells older sockets of the same announcer that `pid` replaces them."
  def supersede(%Announcer{} = a, pid),
    do: broadcast(a.tournament_id, {:nunki_superseded, a.id, pid})

  ## ---------- the countdown ----------

  @doc """
  Starts the round countdown for the latest published round, `minutes`
  long, replacing any that runs, and tells every announcer.
  `{:error, :no_round}` while nothing is published, `{:error, :minutes}`
  for a length the page does not offer.
  """
  def start_countdown(%Scope{} = scope, %Tournament{} = tournament, minutes) do
    tournament = authorize!(scope, tournament)
    round = Tournaments.latest_published_round_number(tournament)

    cond do
      minutes not in @countdown_minutes ->
        {:error, :minutes}

      round == 0 ->
        {:error, :no_round}

      true ->
        now = now()

        cd = %Countdown{
          tournament_id: tournament.id,
          round: round,
          token: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower),
          ends_at: DateTime.add(now, minutes * 60)
        }

        {:ok, cd} =
          Repo.transaction(fn ->
            Repo.delete_all(from c in Countdown, where: c.tournament_id == ^tournament.id)
            Repo.insert!(cd)
          end)

        broadcast(tournament.id, {:nunki_send, countdown_frame(cd, now)})
        notify(tournament.id)
        {:ok, cd}
    end
  end

  @doc "Cancels the running countdown and tells every announcer. `{:error, :none}` when none runs."
  def cancel_countdown(%Scope{} = scope, %Tournament{} = tournament) do
    tournament = authorize!(scope, tournament)

    case Repo.get_by(Countdown, tournament_id: tournament.id) do
      nil ->
        {:error, :none}

      cd ->
        Repo.delete!(cd)
        broadcast(tournament.id, {:nunki_send, Protocol.countdown_cancel(cd.token)})
        notify(tournament.id)
        :ok
    end
  end

  @doc "The countdown still running for the tournament, or nil (none, or run out)."
  def current_countdown(tournament_id, now \\ now()) do
    case Repo.get_by(Countdown, tournament_id: tournament_id) do
      %Countdown{} = cd -> if seconds_left(cd, now) > 0, do: cd, else: nil
      nil -> nil
    end
  end

  @doc "Whole seconds until the countdown ends, never below zero."
  def seconds_left(%Countdown{ends_at: ends_at}, now \\ now()),
    do: max(DateTime.diff(ends_at, now), 0)

  @doc "The `countdown` frame for `cd` as of `now`."
  def countdown_frame(%Countdown{} = cd, now \\ now()),
    do: Protocol.countdown(cd.round, seconds_left(cd, now), cd.token)

  ## ---------- reading aloud ----------

  @doc "Asks every announcer to read the latest published round aloud. `{:error, :no_round}` before one is."
  def read_aloud(%Scope{} = scope, %Tournament{} = tournament) do
    tournament = authorize!(scope, tournament)

    case Tournaments.latest_published_round_number(tournament) do
      0 ->
        {:error, :no_round}

      round ->
        broadcast(tournament.id, {:nunki_send, Protocol.read(round)})
        {:ok, round}
    end
  end

  @doc "Asks every announcer to stop speaking."
  def stop_reading(%Scope{} = scope, %Tournament{} = tournament) do
    tournament = authorize!(scope, tournament)
    broadcast(tournament.id, {:nunki_send, Protocol.stop()})
    :ok
  end

  ## ---------- helpers ----------

  defp authorize!(scope, %Tournament{id: id}),
    do: Tournaments.get_authorized_tournament!(scope, id)

  defp now, do: DateTime.utc_now(:second)

  defp sha256(text), do: :crypto.hash(:sha256, text)

  defp random_code,
    do: :crypto.strong_rand_bytes(@code_bytes) |> Base.url_encode64(padding: false)

  defp random_key, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp clip(text, max) when is_binary(text), do: text |> String.trim() |> String.slice(0, max)
  defp clip(_other, _max), do: ""
end
