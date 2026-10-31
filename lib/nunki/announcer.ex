defmodule Nunki.Announcer do
  @moduledoc """
  What is said when, decided in one place.

    * A round arrives (`round_received/2`): kept as the tournament's latest
      round. When its number has not been announced for this tournament
      yet, and "Read the pairings when they are published" is on, it is
      read aloud. A changed payload for a round already announced (a
      correction, a late entrant) is not read again by itself: the arbiter
      decides that, with "Read now" here or "Read the pairings aloud" in
      OpenPairings.
    * `read/2`: that round, now.
    * `milestone/3`: the countdown's words, at ten, five, one minute and
      zero.

  In which language: the tournament's (`locale` in the round payload, which
  is the OpenPairings account's language), unless the operator chose one on
  the control page. Before any round has arrived there is no tournament
  language, and it is English.
  """

  alias Nunki.{Script, Speaker, Store}

  @doc "\"en\" or \"nl\": the language the tournament is announced in."
  def language(tournament_id) do
    case Store.setting("language") do
      lang when lang in ["en", "nl"] ->
        lang

      _follow ->
        case Store.tournament(tournament_id) do
          %{"round" => %{"locale" => "nl"}} -> "nl"
          _other -> "en"
        end
    end
  end

  @doc """
  A round payload from the server. `:read` when it was read aloud, `:kept`
  otherwise.
  """
  def round_received(tournament_id, %{"round" => round} = payload) when is_integer(round) do
    result =
      Store.update_tournament(tournament_id, fn t ->
        t
        |> Map.put("round", payload)
        |> Map.put("announced", max(t["announced"] || 0, round))
      end)

    case result do
      {:ok, %{"announced" => before}, _after} when round > before ->
        if Store.setting("read_on_publish") == false do
          :kept
        else
          speak_pairings(tournament_id, payload)
          :read
        end

      _already_or_gone ->
        :kept
    end
  end

  def round_received(_tournament_id, _payload), do: :kept

  @doc """
  Reads a round's pairings now. `round` nil is the latest; a round other
  than the latest one held is not known here (`{:error, :unknown_round}`).
  """
  def read(tournament_id, round \\ nil) do
    case Store.tournament(tournament_id) do
      %{"round" => %{"round" => held} = payload} when round in [nil, held] ->
        speak_pairings(tournament_id, payload)
        :ok

      %{"round" => _other} ->
        {:error, :unknown_round}

      nil ->
        {:error, :unknown_tournament}
    end
  end

  @doc "Says a countdown's milestone."
  def milestone(tournament_id, which, round) do
    lang = language(tournament_id)
    Speaker.say([Script.milestone(which, round, lang)], lang, tournament: tournament_id)
  end

  @doc """
  Says an announcement now (the server's `announce`, or the control page's
  buttons): `a` is `%{"id", "canned", "text"}`. Kept as the tournament's
  last announcement for the hall screen and the control page; an `id` that
  is the last one seen is a repeat and is not said again. `:said`,
  `:repeat` or `:nothing`.
  """
  def announce(tournament_id, %{} = a) do
    lang = language(tournament_id)
    text = Script.announcement(a, lang)
    id = to_string(a["id"] || "")

    if is_nil(text) do
      :nothing
    else
      result =
        Store.update_tournament(tournament_id, fn t ->
          if id != "" and get_in(t, ["announcement", "id"]) == id,
            do: t,
            else:
              Map.put(t, "announcement", %{
                "id" => id,
                "text" => text,
                "at" => System.os_time(:second)
              })
        end)

      case result do
        {:ok, %{"announcement" => %{"id" => ^id}}, _after} when id != "" ->
          :repeat

        {:ok, _before, _after} ->
          Speaker.say([text], lang, tournament: tournament_id)
          Nunki.broadcast({:announcement, tournament_id})
          :said

        :error ->
          :nothing
      end
    end
  end

  @doc "A fresh announcement id."
  def new_announcement_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  defp speak_pairings(tournament_id, payload) do
    lang = language(tournament_id)
    Speaker.say(Script.pairings(payload, lang), lang, tournament: tournament_id)
  end
end
