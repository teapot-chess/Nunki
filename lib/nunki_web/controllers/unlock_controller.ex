defmodule NunkiWeb.UnlockController do
  @moduledoc """
  `/unlock`: where a browser that is not on this machine gives the access
  PIN. A right one puts the PIN's stamp in the session (never the PIN) and
  the session's `live_socket_id`, so that a change of PIN can close the
  socket; a wrong one is counted by `Nunki.DoorGuard` *before* it is
  compared, and a browser that has to wait is told how long, even if the PIN
  it gave was the right one.
  """
  use NunkiWeb, :controller

  alias Nunki.{AccessPin, DoorGuard}
  alias NunkiWeb.{AccessGate, Local, PinText}

  plug :put_view, html: NunkiWeb.UnlockHTML

  def show(conn, _params) do
    if through?(conn), do: redirect(conn, to: "/"), else: page(conn, 200, nil)
  end

  def create(conn, params) do
    if through?(conn) do
      redirect(conn, to: "/")
    else
      guess(conn, get_in(params, ["unlock", "pin"]))
    end
  end

  defp guess(conn, pin) do
    ip = conn.remote_ip

    case DoorGuard.claim(ip) do
      {:wait, seconds} ->
        page(conn, 429, PinText.wait(seconds))

      {:ok, claimed_at} ->
        if AccessPin.valid_guess?(pin) do
          DoorGuard.succeeded(ip, claimed_at)
          to = AccessGate.return_path(conn)

          conn
          |> configure_session(renew: true)
          |> put_session("pin_stamp", AccessPin.stamp())
          |> put_session(:live_socket_id, AccessPin.socket_id())
          |> delete_session("return_to")
          |> redirect(to: to)
        else
          page(conn, 401, gettext("That is not the PIN."))
        end
    end
  end

  defp through?(conn) do
    Local.request?(conn) or AccessPin.granted?(get_session(conn, "pin_stamp"))
  end

  defp page(conn, status, error) do
    conn
    |> put_status(status)
    |> render(:show,
      form: Phoenix.Component.to_form(%{"pin" => ""}, as: :unlock),
      error: error,
      locale: conn.assigns[:locale] || "en",
      page_title: gettext("Nunki")
    )
  end
end
