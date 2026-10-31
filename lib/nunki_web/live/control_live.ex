defmodule NunkiWeb.ControlLive do
  @moduledoc """
  The control page, `/`: the joined tournaments and their lines, the join
  field, how Nunki speaks, and the buttons an arbiter reaches for - Read
  now, Stop, a countdown of their own.

  Everything shown is read from the processes that own it (`Nunki.Store`,
  `Nunki.Countdown`, `Nunki.Speaker`, the links) and re-read when they say
  something changed. The page keeps nothing of its own worth losing.
  """
  use NunkiWeb, :live_view

  alias Nunki.{
    Announcer,
    Autostart,
    Countdown,
    Script,
    Speaker,
    Store,
    Tournaments,
    Updates,
    Voice
  }

  alias NunkiWeb.Words

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Nunki.subscribe()
      Updates.subscribe()
    end

    {:ok,
     socket
     |> assign(
       page_title: gettext("Nunki"),
       join_form: to_form(%{"link" => ""}, as: :join),
       join_error: nil,
       joining?: false,
       update: Updates.notice(),
       update_step: nil,
       update_busy: [],
       drafts: %{},
       ticking?: false
     )
     |> load()}
  end

  # --- what the page shows ---------------------------------------------------

  defp load(socket) do
    rows = rows(socket.assigns.drafts)
    settings = Store.settings()
    voices = Voice.list()

    socket
    |> assign(
      tournament_count: length(rows),
      speaker: speaker_status(),
      voices_en: Voice.for_language(voices, "en"),
      voices_nl: Voice.for_language(voices, "nl"),
      engine: engine(),
      update_mode: Updates.mode(),
      install_kind: Updates.install_kind(),
      autostart?: Autostart.supported?() and Autostart.enabled?(),
      speech_form: speech_form(settings),
      advanced?: settings["advanced"] == true,
      device_form: to_form(%{"name" => Store.device_name()}, as: :device)
    )
    |> stream(:tournaments, rows, reset: true)
    |> tick(Enum.any?(rows, & &1.countdown))
  end

  # `drafts` holds what is typed into a tournament's name and room fields and
  # not sent yet, so a reload (every second during a countdown) does not eat it.
  defp rows(drafts) do
    for t <- Tournaments.list() do
      payload = t["round"]
      announcer = t["announcer"] || %{}

      values =
        Map.merge(
          %{
            "tournament" => t["id"],
            "name" => announcer["name"] || Store.device_name(),
            "room" => announcer["room"] || ""
          },
          drafts[t["id"]] || %{}
        )

      %{
        id: t["id"],
        name: get_in(t, ["tournament", "name"]) || "",
        server: t["server"],
        up?: t["up?"] == true,
        error: Words.link_error(t["error"]),
        round: payload && payload["round"],
        rounds: payload && payload["rounds"],
        boards: payload && length(payload["boards"] || []),
        countdown: Countdown.get(t["id"]),
        announcement: get_in(t, ["announcement", "text"]),
        announcer_name: announcer["name"],
        announcer_room: announcer["room"] || "",
        room_options: room_options(announcer, values["room"]),
        settings_form: to_form(values, as: :announcer, id: "tournaments-#{t["id"]}-settings")
      }
    end
  end

  # With a list of rooms from the server: "No room", the rooms, and, so a
  # row that has one is not silently changed, the current value when it is
  # free text from before rooms. Without one (an older server): nil, and the
  # field stays a text field.
  defp room_options(%{"rooms_available" => names}, value) when is_list(names) do
    legacy = if value in [nil, ""] or value in names, do: [], else: [value]
    [{gettext("No room"), ""} | Enum.map(names ++ legacy, &{&1, &1})]
  end

  defp room_options(_announcer, _value), do: nil

  defp speech_form(settings) do
    voices = settings["voices"] || %{}

    to_form(
      %{
        "language" => settings["language"] || "follow",
        "read_on_publish" => settings["read_on_publish"] != false,
        "voice_en" => voice_value("en", voices),
        "voice_nl" => voice_value("nl", voices)
      },
      as: :speech
    )
  end

  defp voice_value(lang, chosen) do
    case Voice.resolve(lang, Voice.list(), chosen) do
      %{id: id} -> id
      nil -> ""
    end
  end

  defp speaker_status do
    Speaker.status()
  catch
    :exit, _not_running -> %{speaking?: false, line: nil, queued: 0, error: nil, tournament: nil}
  end

  defp engine do
    Voice.engine()
  rescue
    _error -> nil
  end

  # One tick a second while a countdown runs, so the minutes on the page move.
  defp tick(socket, true) do
    unless socket.assigns.ticking?, do: Process.send_after(self(), :tick, 1000)
    assign(socket, ticking?: true)
  end

  defp tick(socket, false), do: socket

  # --- events ----------------------------------------------------------------------

  @impl true
  def handle_event("join_change", %{"join" => params}, socket) do
    {:noreply, assign(socket, join_form: to_form(params, as: :join), join_error: nil)}
  end

  def handle_event("join", %{"join" => %{"link" => link}}, socket) do
    case Tournaments.join(link, Application.get_env(:nunki, :join_req_options, [])) do
      {:ok, _id} ->
        {:noreply,
         socket
         |> assign(join_form: to_form(%{"link" => ""}, as: :join), join_error: nil)
         |> put_flash(:info, gettext("Joined. The tournament is in the list."))
         |> load()}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           join_form: to_form(%{"link" => link}, as: :join),
           join_error: Words.join_error(reason)
         )}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    Tournaments.remove(id)
    {:noreply, socket |> put_flash(:info, gettext("Removed.")) |> load()}
  end

  def handle_event("announcer_draft", %{"announcer" => %{"tournament" => id} = params}, socket),
    do: {:noreply, assign(socket, drafts: Map.put(socket.assigns.drafts, id, params))}

  def handle_event("announcer_save", %{"announcer" => %{"tournament" => id} = params}, socket) do
    case Tournaments.change_settings(id, params["name"] || "", params["room"] || "") do
      :ok ->
        # The form goes back to what the server says; its answer is on the way.
        {:noreply,
         socket
         |> assign(drafts: Map.delete(socket.assigns.drafts, id))
         |> put_flash(:info, gettext("Sent. The server's answer is what you see here."))
         |> load()}

      {:error, :down} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("The line is down, so the server cannot be asked. Try again when it is up.")
         )}
    end
  end

  def handle_event("read", %{"id" => id}, socket) do
    case Announcer.read(id) do
      :ok ->
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("No pairings to read yet."))}
    end
  end

  def handle_event("stop", _params, socket) do
    Speaker.stop()
    {:noreply, socket}
  end

  def handle_event("countdown_start", %{"tournament" => id, "minutes" => minutes}, socket) do
    with {minutes, ""} <- Integer.parse(to_string(minutes)),
         true <- minutes in Countdown.local_choices(),
         %{"round" => %{"round" => round}} <- Store.tournament(id) do
      {:ok, _id} = Countdown.start(id, round, minutes * 60, source: :local)
      {:noreply, load(socket)}
    else
      _no ->
        {:noreply,
         put_flash(socket, :error, gettext("No pairings yet: nothing to count down to."))}
    end
  end

  def handle_event("announce_canned", %{"tournament" => id, "canned" => canned}, socket)
      when canned in ["silence", "phones", "seats", "results", "arbiter"] do
    Announcer.announce(id, %{"id" => Announcer.new_announcement_id(), "canned" => canned})
    {:noreply, load(socket)}
  end

  def handle_event(
        "announce_text",
        %{"announce" => %{"tournament" => id, "text" => text}},
        socket
      ) do
    case Announcer.announce(id, %{"id" => Announcer.new_announcement_id(), "text" => text}) do
      :nothing -> {:noreply, put_flash(socket, :error, gettext("Type what to announce."))}
      _said -> {:noreply, load(socket)}
    end
  end

  def handle_event("countdown_cancel", %{"id" => id}, socket) do
    Countdown.cancel(id)
    {:noreply, load(socket)}
  end

  def handle_event("speech", %{"speech" => params}, socket) do
    language = if params["language"] in ["en", "nl"], do: params["language"], else: "follow"
    Store.put_setting("language", language)
    Store.put_setting("read_on_publish", params["read_on_publish"] == "true")

    voices =
      for lang <- ["en", "nl"],
          id = params["voice_" <> lang],
          is_binary(id) and id != "",
          into: %{},
          do: {lang, id}

    Store.put_setting("voices", Map.merge(Store.setting("voices") || %{}, voices))
    {:noreply, load(socket)}
  end

  def handle_event("advanced", params, socket) do
    Store.put_setting("advanced", params["on"] == "true")
    {:noreply, load(socket)}
  end

  def handle_event("test_voice", %{"lang" => lang}, socket) when lang in ["en", "nl"] do
    Speaker.say([Script.test_line(lang)], lang)
    {:noreply, socket}
  end

  def handle_event("refresh_voices", _params, socket) do
    Task.Supervisor.start_child(Nunki.TaskSupervisor, fn -> Voice.refresh() end)
    {:noreply, socket}
  end

  def handle_event("device", %{"device" => %{"name" => name}}, socket) do
    Store.put_device_name(name)
    {:noreply, socket |> put_flash(:info, gettext("Saved.")) |> load()}
  end

  def handle_event("update_mode", %{"mode" => mode}, socket) when mode in ["ask", "never"] do
    Updates.put_mode(mode)
    {:noreply, assign(socket, update: Updates.notice()) |> load()}
  end

  def handle_event("update_later", _params, socket) do
    with %{version: version} <- socket.assigns.update, do: Updates.later(version)
    {:noreply, assign(socket, update: nil, update_step: nil)}
  end

  def handle_event("update_never", _params, socket) do
    Updates.put_mode("never")
    {:noreply, assign(socket, update: nil, update_step: nil) |> load()}
  end

  def handle_event("update_apply", params, socket) do
    case Updates.apply(force: params["force"] == "yes") do
      :ok ->
        {:noreply, assign(socket, update_step: :going, update_busy: [])}

      {:error, {:busy, reasons}} ->
        {:noreply, assign(socket, update_step: :busy, update_busy: reasons)}

      {:error, :manual} ->
        {:noreply, assign(socket, update_step: :manual)}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, gettext("The update could not be started."))}
    end
  end

  def handle_event("autostart", params, socket) do
    case Autostart.set(params["on"] == "true") do
      :ok ->
        {:noreply, load(socket)}

      {:error, _words} ->
        {:noreply, put_flash(socket, :error, gettext("Windows would not take that setting."))}
    end
  end

  def handle_event("update_cancel", _params, socket),
    do: {:noreply, assign(socket, update_step: nil, update_busy: [])}

  # --- messages ----------------------------------------------------------------------

  @impl true
  def handle_info(:tick, socket) do
    socket = assign(socket, ticking?: false)
    {:noreply, load(socket)}
  end

  def handle_info({:speaker, status}, socket), do: {:noreply, assign(socket, speaker: status)}

  def handle_info({:room_refused, _tournament}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("That room is not one of this tournament's rooms."))
     |> load()}
  end

  def handle_info(:update_changed, socket),
    do: {:noreply, assign(socket, update: Updates.notice())}

  def handle_info(_changed, socket), do: {:noreply, load(socket)}

  # --- the page ------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} locale={@locale} page={:control}>
      <.update_banner
        :if={@update}
        update={@update}
        step={@update_step}
        busy={@update_busy}
        kind={@install_kind}
      />

      <section id="speaker" class={["panel", "speaker", @speaker.speaking? && "is-speaking"]}>
        <div class="speaker-state">
          <.icon name="speaker" />
          <div>
            <p :if={@speaker.speaking?} id="speaker-line" class="line">{@speaker.line}</p>
            <p :if={!@speaker.speaking?} id="speaker-idle" class="note">
              {gettext("Quiet.")}
            </p>
            <p :if={@speaker.queued > 0} id="speaker-queued" class="note">
              {ngettext("1 more line to say.", "%{count} more lines to say.", @speaker.queued)}
            </p>
            <p :if={@speaker.error} id="speaker-error" class="bad">
              {gettext("The voice did not work: %{error}", error: inspect(@speaker.error))}
            </p>
          </div>
        </div>
        <.button
          id="stop"
          icon="stop"
          variant="danger"
          phx-click="stop"
          disabled={!@speaker.speaking?}
        >
          {gettext("Stop")}
        </.button>
      </section>

      <section id="tournaments-panel" class="panel">
        <header class="panel-head">
          <h2>{gettext("Tournaments")}</h2>
          <.link navigate={~p"/hall"} id="hall-link" class="btn btn-ghost">
            <.icon name="screen" />
            <span>{gettext("Open the hall screen")}</span>
          </.link>
        </header>

        <ul id="tournaments" class="tournaments" phx-update="stream">
          <li id="tournaments-empty" class="empty">
            {gettext(
              "No tournament yet. In OpenPairings: the tournament's Settings → Hall announcer → Add an announcer. Paste the link below."
            )}
          </li>
          <li :for={{dom_id, t} <- @streams.tournaments} id={dom_id} class="tournament">
            <div class="t-main">
              <span
                class={["dot", if(t.up?, do: "up", else: "down")]}
                title={if t.up?, do: gettext("Connected"), else: gettext("Not connected")}
              ></span>
              <div>
                <h3 class="t-name">{t.name}</h3>
                <p class="note">
                  {t.server} · <span :if={t.up?}>{gettext("connected")}</span>
                  <span :if={!t.up?} class="bad">{t.error || gettext("not connected")}</span>
                </p>
                <p class="note" id={"#{dom_id}-round"}>
                  <%= if t.round do %>
                    {gettext("Last pairings received: round %{round} of %{rounds}, %{boards} boards.",
                      round: t.round,
                      rounds: t.rounds || "?",
                      boards: t.boards
                    )}
                  <% else %>
                    {gettext("No pairings received yet.")}
                  <% end %>
                </p>
              </div>
            </div>

            <.form
              :if={@advanced?}
              for={t.settings_form}
              id={"#{dom_id}-settings"}
              class="inline-form t-settings"
              phx-change="announcer_draft"
              phx-submit="announcer_save"
            >
              <.input field={t.settings_form[:tournament]} type="hidden" />
              <.input
                field={t.settings_form[:name]}
                label={gettext("Name")}
                maxlength="60"
                disabled={!t.up?}
              />
              <.input
                :if={t.room_options}
                field={t.settings_form[:room]}
                type="select"
                label={gettext("Room")}
                options={t.room_options}
                disabled={!t.up?}
              />
              <.input
                :if={!t.room_options}
                field={t.settings_form[:room]}
                label={gettext("Room")}
                maxlength="60"
                disabled={!t.up?}
              />
              <.button id={"#{dom_id}-settings-save"} type="submit" disabled={!t.up?}>
                {gettext("Save")}
              </.button>
              <p :if={!t.up?} id={"#{dom_id}-settings-down"} class="note">
                {gettext("Name and room are changed while the line is up; OpenPairings keeps them.")}
              </p>
            </.form>

            <div class="t-countdown">
              <%= if t.countdown do %>
                <p id={"#{dom_id}-countdown"} class="countdown-line">
                  <.icon name="timer" />
                  <%= if t.countdown.started? do %>
                    {gettext("Round %{round} has started.", round: t.countdown.round)}
                  <% else %>
                    {gettext("Round %{round} starts in %{time}.",
                      round: t.countdown.round,
                      time: Words.clock(t.countdown.remaining_ms)
                    )}
                  <% end %>
                </p>
                <.button
                  id={"#{dom_id}-cancel"}
                  variant="ghost"
                  phx-click="countdown_cancel"
                  phx-value-id={t.id}
                >
                  {gettext("Cancel the countdown")}
                </.button>
              <% else %>
                <form
                  id={"#{dom_id}-countdown-form"}
                  class="inline-form"
                  phx-submit="countdown_start"
                >
                  <input type="hidden" name="tournament" value={t.id} />
                  <.input
                    id={"#{dom_id}-minutes"}
                    type="select"
                    name="minutes"
                    value="5"
                    label={gettext("Countdown")}
                    options={minute_options()}
                  />
                  <.button
                    id={"#{dom_id}-countdown-start"}
                    type="submit"
                    icon="timer"
                    disabled={is_nil(t.round)}
                  >
                    {gettext("Start")}
                  </.button>
                </form>
              <% end %>
            </div>

            <div class="t-announce" id={"#{dom_id}-announce"}>
              <p :if={t.announcement} id={"#{dom_id}-last-announcement"} class="note">
                {gettext("Last announcement: %{text}", text: t.announcement)}
              </p>
              <div class="t-actions">
                <.button
                  :for={key <- Nunki.Script.canned_keys()}
                  id={"#{dom_id}-canned-#{key}"}
                  variant="ghost"
                  phx-click="announce_canned"
                  phx-value-tournament={t.id}
                  phx-value-canned={key}
                >
                  {canned_label(key)}
                </.button>
              </div>
              <form
                id={"#{dom_id}-announce-form"}
                class="inline-form"
                phx-submit="announce_text"
              >
                <input type="hidden" name="announce[tournament]" value={t.id} />
                <.input
                  id={"#{dom_id}-announce-text"}
                  type="text"
                  name="announce[text]"
                  value=""
                  label={gettext("Announce")}
                  maxlength="300"
                />
                <.button id={"#{dom_id}-announce-send"} type="submit" icon="play">
                  {gettext("Say it")}
                </.button>
              </form>
            </div>

            <div class="t-actions">
              <.button
                id={"#{dom_id}-read"}
                icon="play"
                phx-click="read"
                phx-value-id={t.id}
                disabled={is_nil(t.round)}
              >
                {gettext("Read now")}
              </.button>
              <.link navigate={~p"/hall?t=#{t.id}"} id={"#{dom_id}-hall"} class="btn btn-ghost">
                <.icon name="screen" />
                <span>{gettext("Hall screen")}</span>
              </.link>
              <.button
                id={"#{dom_id}-remove"}
                icon="trash"
                variant="ghost"
                phx-click="remove"
                phx-value-id={t.id}
                data-confirm={
                  gettext(
                    "Remove this tournament from Nunki? OpenPairings is told, and nothing more is announced for it here."
                  )
                }
              >
                {gettext("Remove")}
              </.button>
            </div>
          </li>
        </ul>

        <.form
          for={@join_form}
          id="join-form"
          class="join"
          phx-change="join_change"
          phx-submit="join"
        >
          <.input
            field={@join_form[:link]}
            type="url"
            label={gettext("Join a tournament")}
            placeholder="https://.../p/nunki/join/..."
            autocomplete="off"
            spellcheck="false"
            hint={
              gettext(
                "The link from OpenPairings: the tournament's Settings → Hall announcer → Add an announcer. Good once, for fifteen minutes."
              )
            }
          />
          <p :if={@join_error} id="join-error" class="bad" role="alert">{@join_error}</p>
          <.button
            id="join-button"
            type="submit"
            variant="primary"
            icon="link"
            phx-disable-with={gettext("Joining...")}
          >
            {gettext("Join")}
          </.button>
        </.form>
      </section>

      <section id="speech-panel" class="panel">
        <header class="panel-head">
          <h2>{gettext("How Nunki speaks")}</h2>
          <.button :if={@advanced?} id="refresh-voices" variant="ghost" phx-click="refresh_voices">
            {gettext("Look for voices again")}
          </.button>
        </header>

        <.form for={@speech_form} id="speech-form" class="speech" phx-change="speech">
          <.input
            field={@speech_form[:language]}
            type="select"
            label={gettext("Language of the announcements")}
            options={[
              {gettext("Follow the tournament"), "follow"},
              {"English", "en"},
              {"Nederlands", "nl"}
            ]}
          />

          <.input
            field={@speech_form[:read_on_publish]}
            type="checkbox"
            label={gettext("Read the pairings when they are published")}
          />

          <div :if={@advanced?} class="voice-row">
            <.input
              :if={@voices_en != []}
              field={@speech_form[:voice_en]}
              type="select"
              label={gettext("English voice")}
              options={Enum.map(@voices_en, &{&1.label, &1.id})}
            />
            <p :if={@voices_en == []} id="no-voice-en" class="note bad">
              {gettext("No English voice on this machine.")} {voice_hint()}
            </p>
            <.button id="test-voice-en" icon="speaker" phx-click="test_voice" phx-value-lang="en">
              {gettext("Test voice")}
            </.button>
          </div>

          <div :if={@advanced?} class="voice-row">
            <.input
              :if={@voices_nl != []}
              field={@speech_form[:voice_nl]}
              type="select"
              label={gettext("Dutch voice")}
              options={Enum.map(@voices_nl, &{&1.label, &1.id})}
            />
            <p :if={@voices_nl == []} id="no-voice-nl" class="note bad">
              {gettext("No Dutch voice on this machine.")} {voice_hint()}
            </p>
            <.button id="test-voice-nl" icon="speaker" phx-click="test_voice" phx-value-lang="nl">
              {gettext("Test voice")}
            </.button>
          </div>

          <p :if={@advanced? or is_nil(@engine)} class="note" id="engine">
            <%= if @engine do %>
              {gettext("Speech engine: %{engine}.", engine: @engine)}
            <% else %>
              <span class="bad">{gettext("No speech engine found on this machine.")}</span>
            <% end %>
          </p>
        </.form>
      </section>

      <section :if={@advanced?} id="device-panel" class="panel">
        <header class="panel-head">
          <h2>{gettext("This device")}</h2>
        </header>

        <.form for={@device_form} id="device-form" class="inline-form" phx-submit="device">
          <.input
            field={@device_form[:name]}
            label={gettext("Name")}
            hint={
              gettext(
                "The name a tournament starts with when you join it. After that, each tournament has its own name above."
              )
            }
          />
          <.button id="device-save" type="submit">{gettext("Save")}</.button>
        </.form>

        <div class="updates" id="updates">
          <p class="note">
            {gettext("Nunki %{version}.", version: Updates.current_version())}
          </p>
          <label class="check" for="update-mode">
            <input
              id="update-mode"
              type="checkbox"
              checked={@update_mode == "ask"}
              phx-click="update_mode"
              phx-value-mode={if @update_mode == "ask", do: "never", else: "ask"}
            />
            <span>{gettext("Look for new versions (one small question to GitHub, every half hour)")}</span>
          </label>
          <label :if={Autostart.supported?()} class="check" for="autostart">
            <input
              id="autostart"
              type="checkbox"
              checked={@autostart?}
              phx-click="autostart"
              phx-value-on={to_string(!@autostart?)}
            />
            <span>{gettext("Start Nunki when Windows starts")}</span>
          </label>
        </div>
      </section>

      <section id="advanced-panel" class="panel">
        <label class="check" for="advanced-toggle">
          <input
            id="advanced-toggle"
            type="checkbox"
            checked={@advanced?}
            phx-click="advanced"
            phx-value-on={to_string(!@advanced?)}
          />
          <span>{gettext("Show advanced features")}</span>
        </label>
        <p class="note">
          {gettext(
            "Choosing voices, testing them, name and room per tournament, this device's name and the update options. Off keeps this page small; none of it stops working."
          )}
        </p>
      </section>
    </Layouts.app>
    """
  end

  defp canned_label("silence"), do: gettext("Silence")
  defp canned_label("phones"), do: gettext("Phones off")
  defp canned_label("seats"), do: gettext("Take your seats")
  defp canned_label("results"), do: gettext("Hand in results")
  defp canned_label("arbiter"), do: gettext("Arbiter's desk")

  defp minute_options do
    for m <- Countdown.local_choices(),
        do: {ngettext("1 minute", "%{count} minutes", m), Integer.to_string(m)}
  end

  defp voice_hint do
    case :os.type() do
      {:win32, _} ->
        gettext("Add the language under Settings, Time & language, Speech.")

      {:unix, :darwin} ->
        gettext("Download one under System Settings, Accessibility, Spoken Content.")

      _linux ->
        gettext("Install espeak-ng (sudo apt install espeak-ng).")
    end
  end

  attr :update, :map, required: true
  attr :step, :atom, default: nil
  attr :busy, :list, default: []
  attr :kind, :atom, required: true

  defp update_banner(assigns) do
    ~H"""
    <div id="update-banner" class="banner" role="status">
      <.icon name="update" />
      <div class="banner-text">
        <p>
          {gettext("Nunki %{version} is out. This one is %{current}.",
            version: @update.version,
            current: Updates.current_version()
          )}
          <span :if={@update.size} id="update-banner-size">
            {gettext("The download is %{size}.", size: Words.megabytes(@update.size))}
          </span>
        </p>

        <p :if={@step == :busy} id="update-busy" class="bad" role="alert">
          {Words.busy(@busy)}
          {gettext(
            "An update stops Nunki for about a minute, and a countdown stopped a minute before zero is a round that starts in silence."
          )}
        </p>
        <p :if={@step == :going} id="update-going">
          {gettext(
            "Updating. Nunki stops and comes back in about a minute; this page reconnects by itself."
          )}
        </p>
        <p :if={@step == :manual or @kind == :manual} id="update-manual" class="note">
          {gettext("This copy does not update itself: download the new version and replace this one.")}
        </p>
      </div>

      <div class="banner-actions">
        <a id="update-banner-notes" href={@update.url} target="_blank" rel="noopener">
          {gettext("What is new")}
        </a>
        <.button
          :if={@kind != :manual and @step not in [:busy, :going]}
          id="update-apply"
          variant="primary"
          phx-click="update_apply"
        >
          {gettext("Install")}
        </.button>
        <.button
          :if={@step == :busy}
          id="update-force"
          variant="danger"
          phx-click="update_apply"
          phx-value-force="yes"
          data-confirm={gettext("Install now anyway? Whatever is running or being said stops.")}
        >
          {gettext("Install anyway")}
        </.button>
        <.button :if={@step == :busy} id="update-cancel" variant="ghost" phx-click="update_cancel">
          {gettext("Not now")}
        </.button>
        <.button :if={@step != :going} id="update-later" variant="ghost" phx-click="update_later">
          {gettext("Later")}
        </.button>
        <.button
          :if={@step != :going}
          id="update-never"
          variant="ghost"
          phx-click="update_never"
          data-confirm={
            gettext(
              "Stop looking for new versions? You can switch it on again under This device, once advanced features are shown."
            )
          }
        >
          {gettext("Don't ask again")}
        </.button>
      </div>
    </div>
    """
  end
end
