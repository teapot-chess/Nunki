defmodule Nunki.Script do
  @moduledoc """
  What is said, in English or Dutch: the words of every announcement.

  Through Gettext (the `speech` domain, `priv/gettext/*/LC_MESSAGES/speech.po`)
  with the locale given explicitly - the tournament's, or the operator's
  override - and never the page's: the arbiter may read the control page in
  English in a Dutch hall.

  Written to be heard, not read: short sentences, numbers a voice reads
  well, white named before black, and one board a sentence, so that a
  player who missed it hears the next one start cleanly.
  """

  use Gettext, backend: NunkiWeb.Gettext

  @doc """
  The pairings of a round payload, line by line: \"Pairings for round 3
  are published.\", then one line a board, white first, then the byes.
  """
  def pairings(%{"round" => round} = payload, locale) do
    with_locale(locale, fn ->
      boards = payload["boards"] || []

      header = dgettext("speech", "Pairings for round %{round} are published.", round: round)

      games =
        for board <- boards, is_map(board["white"]), is_map(board["black"]) do
          dgettext("speech", "Board %{board}: %{white} against %{black}.",
            board: board["board"],
            white: spoken(board["white"]),
            black: spoken(board["black"])
          )
        end

      byes =
        for board <- boards, board["black"] == nil, is_map(board["white"]) do
          dgettext("speech", "%{name} has a bye.", name: spoken(board["white"]))
        end

      [header | games ++ byes]
    end)
  end

  @doc """
  The countdown's milestones: `:ten`, `:five`, `:one` (minutes before the
  round) and `:zero` (now).
  """
  def milestone(which, round, locale) do
    with_locale(locale, fn ->
      case which do
        :ten ->
          dgettext("speech", "Round %{round} starts in ten minutes.", round: round)

        :five ->
          dgettext("speech", "Round %{round} starts in five minutes.", round: round)

        :one ->
          dgettext(
            "speech",
            "Round %{round} starts in one minute. Please go to your board.",
            round: round
          )

        :zero ->
          dgettext("speech", "Round %{round} starts now. Please start the clocks.", round: round)
      end
    end)
  end

  @canned ~w(silence phones seats results arbiter)

  @doc "The canned announcements the contract knows (`announce`'s `canned`)."
  def canned_keys, do: @canned

  @doc """
  What an `announce` says: the canned phrase `canned` in `locale`, or, when
  there is none or this Nunki does not know it, the free `text` as it is.
  `nil` when there is nothing to say.
  """
  def announcement(%{"canned" => canned}, locale) when canned in @canned do
    with_locale(locale, fn ->
      case canned do
        "silence" -> dgettext("speech", "Silence, please.")
        "phones" -> dgettext("speech", "Please switch off your mobile phones.")
        "seats" -> dgettext("speech", "Players, please take your seats.")
        "results" -> dgettext("speech", "Please hand in your results to the arbiter.")
        "arbiter" -> dgettext("speech", "Please come to the arbiter's desk.")
      end
    end)
  end

  def announcement(%{"text" => text}, _locale) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      text -> String.slice(text, 0, 300)
    end
  end

  def announcement(_other, _locale), do: nil

  @doc "What \"Test voice\" says."
  def test_line(locale) do
    with_locale(locale, fn ->
      dgettext("speech", "This is how announcements in this hall will sound.")
    end)
  end

  @doc """
  The name to say: the payload's `spoken` (\"Magnus Carlsen\"), or one made
  from `name` (\"Carlsen, Magnus\") when a server leaves it out.
  """
  def spoken(%{"spoken" => spoken}) when is_binary(spoken) and spoken != "", do: spoken
  def spoken(%{"name" => name}) when is_binary(name), do: first_last(name)
  def spoken(_player), do: "?"

  @doc "\"Carlsen, Magnus\" -> \"Magnus Carlsen\"; a name without a comma stays."
  def first_last(name) do
    case String.split(name, ",", parts: 2) do
      [last, first] -> String.trim(first) <> " " <> String.trim(last)
      [whole] -> String.trim(whole)
    end
  end

  defp with_locale(locale, fun) do
    Gettext.with_locale(NunkiWeb.Gettext, if(locale == "nl", do: "nl", else: "en"), fun)
  end
end
