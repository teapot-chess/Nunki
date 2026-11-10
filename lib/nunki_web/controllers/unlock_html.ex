defmodule NunkiWeb.UnlockHTML do
  @moduledoc "The page `/unlock` shows: one field for the PIN, and a way to see what was typed."
  use NunkiWeb, :html

  def show(assigns) do
    ~H"""
    <div class="frame">
      <header id="top" class="top">
        <span class="brand" id="brand">
          <.logo />
          <span>Nunki</span>
        </span>
        <Layouts.language locale={@locale} return_to="/unlock" />
      </header>

      <main class="page">
        <section id="unlock" class="panel">
          <header class="panel-head">
            <h1>{gettext("PIN needed")}</h1>
          </header>

          <p class="note">
            {gettext(
              "Nunki asks every other computer for the PIN. It is on Nunki's own control page."
            )}
          </p>

          <p id="unlock-headless" class="note">
            {gettext(
              "On a box without a screen it is in the file access-pin in Nunki's data folder (on Linux: sudo cat /var/lib/nunki/access-pin)."
            )}
          </p>

          <p :if={@error} id="unlock-error" class="bad" role="alert">{@error}</p>

          <.form for={@form} id="unlock-form" action={~p"/unlock"} method="post" class="inline-form">
            <.input
              field={@form[:pin]}
              id="unlock-pin"
              type="password"
              label={gettext("PIN")}
              autocomplete="off"
              maxlength="64"
              spellcheck="false"
              required
            />
            <.button
              id="unlock-show"
              type="button"
              variant="ghost"
              phx-click={JS.toggle_attribute({"type", "password", "text"}, to: "#unlock-pin")}
            >
              {gettext("Show")}
            </.button>
            <.button id="unlock-submit" type="submit" variant="primary">
              {gettext("Open")}
            </.button>
          </.form>
        </section>
      </main>
    </div>
    """
  end
end
