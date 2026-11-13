defmodule NunkiWeb.HallLive do
  @moduledoc """
  The hall screen, `/hall`: dark, full-screen, readable from the back row.
  A countdown when there is one ("Round 3 starts in 4:59", then "Round 3
  has started"), the latest pairings when there is not, and the line Nunki
  is saying at the bottom.

  `?screen=hdmi1|hdmi2` says which of the box's screens this is (`/hall`
  alone is `hdmi1`); each has its own mode and tournament (`Nunki.Hall`).
  `?t=<id>` shows one tournament whatever the screen was told. Without
  either: the one whose countdown runs, else the first joined. It is in the
  tournament's announcement language, not the page's: the people reading it
  are the ones being announced to.

  The modes:

    * `live` - everything above, as it changes;
    * `paused` - what the screen showed when it was paused stays, clock and
      all, until it is live again. A page opened while paused shows what is
      there at that moment and then stays put. Speech is not paused;
    * `black` - nothing: no text, no button, no cursor. What changes
      meanwhile is followed, out of sight, so that going live (or paused)
      from black shows the present, not the moment the lights went out.

  The screen is a convenience. Nunki speaks whether it is open or not;
  that is the whole point of speaking through the system rather than
  through a browser tab (see the README). With the sound switched off,
  nothing is said, so the line at the bottom stays away too; the pairings,
  the countdown and the announcements are still shown.
  """
  use NunkiWeb, :live_view

  alias Nunki.{Announcer, Countdown, Hall, Speaker, Store}
  alias NunkiWeb.Words

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket), do: Nunki.subscribe()
    screen = Hall.screen_name(params["screen"])
    setting = Hall.screen(screen)

    {:ok,
     socket
     |> assign(
       page_title: gettext("Hall screen"),
       wanted: params["t"],
       screen: screen,
       mode: setting["mode"],
       chosen: setting["tournament"],
       identify?: false,
       ticking?: false
     )
     |> stream_configure(:boards, dom_id: &"board-#{&1["board"]}")
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    screen = Hall.screen_name(params["screen"])

    socket =
      if screen == socket.assigns.screen do
        socket
      else
        setting = Hall.screen(screen)
        assign(socket, screen: screen, mode: setting["mode"], chosen: setting["tournament"])
      end

    {:noreply, socket |> assign(wanted: params["t"]) |> load()}
  end

  defp load(socket) do
    tournaments = Store.tournaments()
    countdowns = Countdown.all()
    t = Hall.pick(tournaments, countdowns, socket.assigns.wanted, socket.assigns.chosen)
    id = t && t["id"]
    lang = if t, do: Announcer.language(id), else: socket.assigns.locale
    Gettext.put_locale(NunkiWeb.Gettext, lang)

    payload = t && t["round"]
    countdown = id && Countdown.get(id)

    socket
    |> assign(
      tournament: t,
      name: (t && get_in(t, ["tournament", "name"])) || "",
      lang: lang,
      round: payload && payload["round"],
      rounds: payload && payload["rounds"],
      has_boards?: payload != nil and (payload["boards"] || []) != [],
      countdown: countdown,
      announcement: recent_announcement(t),
      speaker: speaker_status()
    )
    |> stream(:boards, (payload && payload["boards"]) || [], reset: true)
    |> tick(countdown != nil or announcement_recent?(t))
  end

  @announcement_show_s 90

  # The last announcement, while it is news: a minute and a half.
  defp recent_announcement(nil), do: nil

  defp recent_announcement(t) do
    case t["announcement"] do
      %{"text" => text, "at" => at} when is_integer(at) ->
        if System.os_time(:second) - at <= @announcement_show_s, do: text

      _none ->
        nil
    end
  end

  defp announcement_recent?(t), do: recent_announcement(t) != nil

  defp speaker_status do
    Speaker.status()
  catch
    :exit, _not_running -> %{speaking?: false, line: nil}
  end

  defp tick(socket, true) do
    unless socket.assigns.ticking?, do: Process.send_after(self(), :tick, 1000)
    assign(socket, ticking?: true)
  end

  defp tick(socket, false), do: socket

  @impl true
  # This screen was told something. Out of black or into pause, the page is
  # read again: black followed nothing visible, and a pause holds what is
  # there now. Into black nothing needs reading.
  def handle_info({:hall_screen, screen, setting}, %{assigns: %{screen: screen}} = socket) do
    before = socket.assigns
    socket = assign(socket, mode: setting["mode"], chosen: setting["tournament"])

    reload? =
      case setting["mode"] do
        "live" -> true
        "paused" -> before.mode == "black"
        "black" -> false
      end

    {:noreply, if(reload?, do: load(socket), else: socket)}
  end

  def handle_info({:hall_screen, _other_screen, _setting}, socket), do: {:noreply, socket}

  def handle_info({:identify, ms}, socket) do
    Process.send_after(self(), :identify_done, ms)
    {:noreply, assign(socket, identify?: true)}
  end

  def handle_info(:identify_done, socket), do: {:noreply, assign(socket, identify?: false)}

  # Paused: nothing moves, the clock included.
  def handle_info(_changed, %{assigns: %{mode: "paused"}} = socket),
    do: {:noreply, assign(socket, ticking?: false)}

  def handle_info(:tick, socket), do: {:noreply, socket |> assign(ticking?: false) |> load()}

  def handle_info({:speaker, status}, socket), do: {:noreply, assign(socket, speaker: status)}
  def handle_info(_changed, socket), do: {:noreply, load(socket)}

  @impl true
  def render(%{mode: "black"} = assigns) do
    ~H"""
    <Layouts.hall flash={%{}}>
      <div id="hall-black" class="hall-black" data-screen={@screen}>
        <.identify :if={@identify?} screen={@screen} />
      </div>
    </Layouts.hall>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.hall flash={@flash}>
      <div
        id="hall"
        class={["hall", @mode == "paused" && "is-paused"]}
        lang={@lang}
        data-screen={@screen}
        data-mode={@mode}
      >
        <.identify :if={@identify?} screen={@screen} />
        <header class="hall-top">
          <span class="hall-brand"><.logo /> <span>{@name}</span></span>
          <button
            id="fullscreen"
            type="button"
            class="hall-fullscreen"
            phx-hook=".Fullscreen"
            aria-label={gettext("Full screen")}
          >
            <.icon name="expand" />
          </button>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".Fullscreen">
            export default {
              mounted() {
                this.el.addEventListener("click", () => {
                  if (document.fullscreenElement) {
                    document.exitFullscreen()
                  } else {
                    document.documentElement.requestFullscreen().catch(() => {})
                  }
                })
              }
            }
          </script>
        </header>

        <p :if={@announcement} id="hall-announcement" class="hall-announcement" role="alert">
          {@announcement}
        </p>

        <%= cond do %>
          <% @countdown && !@countdown.started? -> %>
            <section id="hall-countdown" class="hall-countdown">
              <p class="hall-label">
                {gettext("Round %{round} starts in", round: @countdown.round)}
              </p>
              <p id="hall-clock" class="hall-clock">{Words.clock(@countdown.remaining_ms)}</p>
            </section>
          <% @countdown && @countdown.started? -> %>
            <section id="hall-started" class="hall-countdown">
              <p class="hall-clock hall-started">
                {gettext("Round %{round} has started", round: @countdown.round)}
              </p>
            </section>
          <% @has_boards? -> %>
            <section id="hall-pairings" class="hall-pairings">
              <h1>{gettext("Round %{round}", round: @round)}</h1>
              <ol id="hall-boards" class="hall-boards" phx-update="stream">
                <li :for={{dom_id, b} <- @streams.boards} id={dom_id}>
                  <span class="hb-board">{b["board"]}</span>
                  <%= if b["black"] do %>
                    <span class="hb-white">{player(b["white"])}</span>
                    <span class="hb-dash">-</span>
                    <span class="hb-black">{player(b["black"])}</span>
                  <% else %>
                    <span class="hb-white">{player(b["white"])}</span>
                    <span class="hb-dash"></span>
                    <span class="hb-black hb-bye">{gettext("bye")}</span>
                  <% end %>
                </li>
              </ol>
            </section>
          <% true -> %>
            <section id="hall-idle" class="hall-idle">
              <.logo class="hall-idle-mark" />
              <p>
                <%= if @tournament do %>
                  {gettext("Waiting for the pairings.")}
                <% else %>
                  {gettext("No tournament joined yet.")}
                <% end %>
              </p>
            </section>
        <% end %>

        <footer :if={@speaker.speaking?} id="hall-line" class="hall-line" aria-live="polite">
          <.icon name="speaker" />
          <span>{@speaker.line}</span>
        </footer>
      </div>
    </Layouts.hall>
    """
  end

  attr :screen, :string, required: true

  # The screen's number, as large as the screen: which monitor is which.
  defp identify(assigns) do
    ~H"""
    <div id="hall-identify" class="hall-identify" aria-hidden="true">
      {String.replace_prefix(@screen, "hdmi", "")}
    </div>
    """
  end

  defp player(%{"name" => name} = p) do
    case p["title"] do
      title when is_binary(title) and title != "" -> "#{title} #{name}"
      _none -> name
    end
  end

  defp player(_none), do: ""
end
