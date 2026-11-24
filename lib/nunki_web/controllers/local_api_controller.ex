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

  def screen_source(conn, _params) do
    with {:ok, body} <- body(conn),
         {:ok, screen} <- screen_param(body),
         {:ok, source} <-
           fetch(body, "source", &is_binary/1, "source must be hall, web or boards"),
         {:ok, url} <-
           fetch(body, "url", &(is_nil(&1) or is_binary(&1)), "url must be an address or null",
             optional: true
           ),
         {:ok, boards} <-
           fetch(body, "boards", &is_binary/1, "boards must be text such as 1-4 or 1-3,7",
             optional: true
           ),
         :ok <- Hall.put_source(screen, source, url, boards) |> source_words() do
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
           "source" => s["source"],
           "url" => s["url"],
           "boards" => s["boards"],
           "boards_url" => Hall.boards_url(shown && shown["results"], s["boards"]),
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
            "connected" => t["up?"] == true,
            "results" => t["results"]
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

  defp fetch(body, key, valid?, message, opts \\ []) do
    case Map.fetch(body, key) do
      {:ok, value} -> if valid?.(value), do: {:ok, value}, else: {:error, 422, message}
      :error -> if opts[:optional], do: {:ok, nil}, else: {:error, 422, message}
    end
  end

  defp source_words(:ok), do: :ok
  defp source_words({:error, :source}), do: {:error, 422, "source must be hall, web or boards"}

  defp source_words({:error, :boards}),
    do:
      {:error, 422,
       "boards must be empty (all boards) or boards like 1-4, 5-10, 1,3,7 or 1-3,7 " <>
         "(numbers 1 to 999, at most 20 items, at most 100 characters)"}

  defp source_words({:error, :no_url}),
    do: {:error, 422, "a web page needs an address (url)"}

  defp source_words({:error, {:url, why}}), do: {:error, 422, url_words(why)}
  defp source_words({:error, _other}), do: {:error, 422, "that is not a screen"}

  defp url_words(:empty), do: "the address is empty"
  defp url_words(:too_long), do: "the address is too long (2000 characters at most)"
  defp url_words(:invalid), do: "that is not a web address (https://host/path)"
  defp url_words(:credentials), do: "the address must not contain a user name or password"

  defp url_words(:scheme),
    do: "the address must start with https:// (http:// only on the local network)"

  defp url_words(:insecure),
    do:
      "http:// is only accepted for this machine and the local network " <>
        "(localhost, 10.x, 172.16-31.x, 192.168.x, *.local); use https:// for anything else"

  defp words(:ok, _message), do: :ok
  defp words({:error, _why}, message), do: {:error, 422, message}

  defp refuse(conn, {:error, status, message}) do
    conn |> put_status(status) |> json(%{"error" => message})
  end
end
