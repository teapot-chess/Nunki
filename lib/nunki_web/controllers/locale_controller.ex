defmodule NunkiWeb.LocaleController do
  @moduledoc "`POST /locale`: remember the pages' language, go back to where you were."

  use NunkiWeb, :controller

  def set(conn, %{"locale" => locale} = params) when locale in ["en", "nl"] do
    conn |> put_session("locale", locale) |> redirect(to: back(params))
  end

  def set(conn, params), do: redirect(conn, to: back(params))

  # Back to one of our own pages, never to wherever a form said.
  defp back(%{"return_to" => path}) when path in ["/", "/hall", "/help", "/unlock"], do: path
  defp back(_params), do: "/"
end
