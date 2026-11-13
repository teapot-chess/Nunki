defmodule NunkiWeb.Layouts do
  @moduledoc """
  The frame of the pages: `root/1` (the document), `app/1` (the header with
  the mark, the three pages and the language, then the flash and the page)
  and `hall/1` for the hall screen, which has no frame at all - it is on a
  projector, and nobody in the back row needs a menu.
  """
  use NunkiWeb, :html

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang={assigns[:locale] || "en"}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <.live_title default="Nunki">{assigns[:page_title]}</.live_title>
        <link rel="icon" type="image/svg+xml" href="/favicon.svg" />
        <link phx-track-static rel="stylesheet" href={~p"/assets/css/app.css"} />
        <script defer phx-track-static type="text/javascript" src={~p"/assets/js/app.js"}>
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  attr :flash, :map, required: true
  attr :locale, :string, default: "en"
  attr :page, :atom, values: [:control, :hall, :help], default: :control

  attr :wide, :boolean,
    default: false,
    doc: "the control page: a management display, as wide as the screen allows"

  attr :update, :map,
    default: nil,
    doc: "`Nunki.Updates.notice/0`; the control page has its own, with the buttons"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class={["frame", @wide && "frame-wide"]}>
      <header id="top" class="top">
        <a href={~p"/"} class="brand" id="brand">
          <.logo />
          <span>Nunki</span>
        </a>

        <nav class="nav" aria-label={gettext("Pages")}>
          <.link navigate={~p"/"} id="nav-control" aria-current={@page == :control && "page"}>
            {gettext("Control")}
          </.link>
          <.link navigate={~p"/hall"} id="nav-hall">
            {gettext("Hall screen")}
          </.link>
          <.link navigate={~p"/help"} id="nav-help" aria-current={@page == :help && "page"}>
            {gettext("Help")}
          </.link>
        </nav>

        <.language locale={@locale} return_to={if @page == :help, do: "/help", else: "/"} />
      </header>

      <.flash_group flash={@flash} />

      <div :if={@update && @page != :control} id="update-banner" class="banner" role="status">
        <.icon name="update" />
        <p class="banner-text">
          {gettext("Nunki %{version} is out.", version: @update.version)}
          <.link id="update-banner-control" navigate={~p"/"}>
            {gettext("Install it on the control page")}
          </.link>
        </p>
      </div>

      <main class="page">
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  attr :flash, :map, required: true
  slot :inner_block, required: true

  def hall(assigns) do
    ~H"""
    <.flash_group flash={@flash} />
    {render_slot(@inner_block)}
    """
  end

  attr :locale, :string, required: true
  attr :return_to, :string, default: "/"

  @doc "EN | NL, as a form: switching the language is a change, not a link to follow."
  def language(assigns) do
    ~H"""
    <form id="language" class="language" method="post" action={~p"/locale"}>
      <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
      <input type="hidden" name="return_to" value={@return_to} />
      <span class="sr-only">{gettext("Language")}</span>
      <button
        id="lang-en"
        type="submit"
        name="locale"
        value="en"
        aria-pressed={to_string(@locale == "en")}
      >
        EN
      </button>
      <button
        id="lang-nl"
        type="submit"
        name="locale"
        value="nl"
        aria-pressed={to_string(@locale == "nl")}
      >
        NL
      </button>
    </form>
    """
  end

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} class="flash-group" aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
      <div
        id="disconnected"
        class="flash error"
        hidden
        phx-disconnected={JS.show(to: "#disconnected")}
        phx-connected={JS.hide(to: "#disconnected")}
      >
        <.icon name="error" />
        <p>{gettext("Lost the connection to Nunki. Trying again...")}</p>
      </div>
    </div>
    """
  end
end
