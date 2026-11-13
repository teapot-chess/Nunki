defmodule NunkiWeb.LocalApiController do
  @moduledoc """
  The local control API, v1: what a touch menu on the same box (the Pi
  image's setup menu) uses to drive the hall screens and the sound. JSON in,
  JSON out, no session, no CSRF token - it is not a browser form, and
  `NunkiWeb.Plugs.LocalOnly` lets nothing but this machine's own programs
  in. The contract is docs/local-api.md; the image depends on it, so a
  change that breaks it is a v2, not an edit.

  Every POST answers with the whole state, as `GET /state` does, so the
  caller never has to ask twice.
  """
  use NunkiWeb, :controller

  alias Nunki.{Countdown, Hall, Speaker, Tournaments}

  @max_body 16_384

  def state(conn, _params), do: json(conn, state())

  def screen(conn, _params) do
    with {:ok, body} <- body(conn),
         {:ok, screen} <- screen_param(body),
         {:ok, mode} <- fetch(body, "mode", &is_binary/1, "mode must be live, paused or black"),
         :ok <- Hall.put_mode(screen, mode) |> words("mode must be live, paused or black") do
      json(conn, state())
    else
      error -> refuse(conn, error)
    end
  end

  def audio(conn, _params) do
    with {:ok, body} <- body(conn),
         {:ok, on?} <- fetch(body, "enabled", &is_boolean/1, "enabled must be true or false") do
      :ok = Hall.put_audio(on?)
      json(conn, state())
    else
      error -> refuse(conn, error)
    end
  end

  def hall_tournament(conn, _params) do
    with {:ok, body} <- body(conn),
         {:ok, screen} <- screen_param(body),
         {:ok, id} <-
           fetch(body, "id", &(is_nil(&1) or is_binary(&1)), "id must be a tournament id or null"),
         :ok <- Hall.put_tournament(screen, id) |> words("no tournament with that id here") do
      json(conn, state())
    else
      error -> refuse(conn, error)
    end
  end

  def identify(conn, _params) do
    :ok = Hall.identify()
    json(conn, state())
  end

  def stop(conn, _params) do
    Speaker.stop()
    json(conn, state())
  end

  # --- the state ------------------------------------------------------------------

  @doc false
  def state do
    screens = Hall.all()
    tournaments = Tournaments.list()

    screens_out =
      Map.new(screens, fn {name, s} ->
        shown = Hall.shown(name)

        {name,
         %{
           "mode" => s["mode"],
           "tournament" => s["tournament"],
           "shows" => shown && shown["id"],
           "countdown" => shown && countdown(shown["id"])
         }}
      end)

    hdmi1 = screens_out["hdmi1"]

    %{
      "screen" => hdmi1["mode"],
      "audio" => Hall.audio?(),
      "hall_tournament" => hdmi1["tournament"],
      "screens" => screens_out,
      "tournaments" =>
        for t <- tournaments do
          %{
            "id" => t["id"],
            "name" => get_in(t, ["tournament", "name"]) || "",
            "connected" => t["up?"] == true
          }
        end,
      "countdown" => hdmi1["countdown"],
      "speaking" => speaking?(),
      "version" => Nunki.version()
    }
  end

  defp countdown(id) do
    case Countdown.get(id) do
      nil ->
        nil

      c ->
        ends_at =
          DateTime.utc_now()
          |> DateTime.add(c.remaining_ms, :millisecond)
          |> DateTime.truncate(:second)

        %{
          "tournament_id" => id,
          "round" => c.round,
          "ends_at" => DateTime.to_iso8601(ends_at),
          "started" => c.started?
        }
    end
  end

  defp speaking?, do: Speaker.speaking?()

  # --- the request ----------------------------------------------------------------

  defp body(conn) do
    with :ok <- json_type(conn),
         {:ok, text, _conn} <- Plug.Conn.read_body(conn, length: @max_body),
         {:ok, %{} = body} <- Jason.decode(text) do
      {:ok, body}
    else
      {:error, :type} -> {:error, 415, "send JSON (Content-Type: application/json)"}
      {:more, _partial, _conn} -> {:error, 413, "the body is too large"}
      _not_an_object -> {:error, 422, "the body must be a JSON object"}
    end
  end

  defp json_type(conn) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      [type | _] -> if type =~ ~r/\Aapplication\/json\b/i, do: :ok, else: {:error, :type}
      [] -> {:error, :type}
    end
  end

  defp screen_param(body) do
    case Map.get(body, "screen", "hdmi1") do
      screen when is_binary(screen) ->
        if screen in Hall.screens(),
          do: {:ok, screen},
          else: {:error, 422, "screen must be one of: " <> Enum.join(Hall.screens(), ", ")}

      _other ->
        {:error, 422, "screen must be one of: " <> Enum.join(Hall.screens(), ", ")}
    end
  end

  defp fetch(body, key, valid?, message) do
    case Map.fetch(body, key) do
      {:ok, value} -> if valid?.(value), do: {:ok, value}, else: {:error, 422, message}
      :error -> {:error, 422, message}
    end
  end

  defp words(:ok, _message), do: :ok
  defp words({:error, _why}, message), do: {:error, 422, message}

  defp refuse(conn, {:error, status, message}) do
    conn |> put_status(status) |> json(%{"error" => message})
  end
end
