defmodule Nunki.AccessPin do
  @moduledoc """
  The access PIN: what every browser that is not on this machine has to give
  before it sees any page, the hall screen included.

  There is always one. It lives in plaintext in `<data>/access-pin` (one line,
  mode 0600, written to `access-pin.new` and renamed over), because it has to
  be shown on the control page and, on a Raspberry Pi image, by the box's own
  script, which reads that file and never writes it. This module is the
  file's only writer. The PIN is kept in memory after it is read; it is never
  logged, never in a URL, and never in a cookie except as `stamp/0`: an HMAC
  keyed with the secret key base, which says "the PIN was this one" without
  being it. A change of PIN changes the stamp, and every grant given earlier
  stops being good at once.

  `<data>/pin-request` is how the box asks for a PIN before Nunki starts:
  `set\\n<pin>\\n` or `new\\n`. `start_link/1` reads it, applies it and
  deletes it, whatever came of it, then makes sure there is a PIN, all while
  the supervisor is starting its children, so the endpoint, which comes
  after, never serves a page without one. Anything else in the file,
  `remove` included, is refused: a PIN cannot be taken away.
  """

  require Logger

  @file_name "access-pin"
  @request_name "pin-request"
  @key {__MODULE__, :pin}
  @min 6
  @max 64
  @topic "access_pin"

  @type reason :: :invalid_utf8 | :padded | :control | :too_short | :too_long | :write

  # --- start-up --------------------------------------------------------------

  @doc false
  def child_spec(_opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}, restart: :temporary}

  # A child that works while it is being started and then is not there.
  @doc false
  def start_link(_opts) do
    startup()
    :ignore
  end

  @doc "The start-up step: the box's request first, then a PIN if there is still none."
  def startup do
    consume_request()
    load()
    :ok
  end

  @doc """
  Reads `access-pin` into memory. A missing, unreadable, symlinked or invalid
  file is replaced by a fresh random PIN.
  """
  @spec load() :: String.t()
  def load do
    case read_file() do
      {:ok, pin} ->
        :persistent_term.put(@key, pin)
        pin

      {:error, why} ->
        if why == :unusable do
          Logger.warning(
            "The access PIN file was not usable (not a plain file, or a PIN the rules refuse); a new random PIN replaced it."
          )
        end

        pin = random()
        store_anyway(pin)
        pin
    end
  end

  @doc "The file name inside the data directory."
  def file_name, do: @file_name

  @doc "The box's request file name inside the data directory."
  def request_name, do: @request_name

  def path, do: Path.join(Nunki.Paths.data(), @file_name)

  # --- asking ----------------------------------------------------------------

  @doc "The current PIN."
  @spec current() :: String.t()
  def current do
    case :persistent_term.get(@key, nil) do
      nil -> load()
      pin -> pin
    end
  end

  @doc "Whether `guess` is the PIN (constant time)."
  @spec valid_guess?(term()) :: boolean()
  def valid_guess?(guess) when is_binary(guess), do: Plug.Crypto.secure_compare(guess, current())
  def valid_guess?(_guess), do: false

  @doc """
  Whether `pin` may be a PIN: 6 to 64 characters, valid UTF-8, no space at
  either end, nothing invisible (control characters).
  """
  @spec validate(term()) :: :ok | {:error, reason()}
  def validate(pin) when is_binary(pin) do
    cond do
      not String.valid?(pin) -> {:error, :invalid_utf8}
      String.trim(pin) != pin -> {:error, :padded}
      control?(pin) -> {:error, :control}
      String.length(pin) < @min -> {:error, :too_short}
      String.length(pin) > @max -> {:error, :too_long}
      true -> :ok
    end
  end

  def validate(_other), do: {:error, :too_short}

  defp control?(pin) do
    pin |> String.to_charlist() |> Enum.any?(&(&1 < 32 or &1 in 127..159))
  end

  # --- the stamp -------------------------------------------------------------

  @doc "What a browser is given when it has given the PIN: keyed, and not the PIN."
  @spec stamp() :: String.t()
  def stamp, do: stamp(current())

  @doc false
  def stamp(pin) do
    :hmac
    |> :crypto.mac(:sha256, secret(), "access-pin:" <> pin)
    |> binary_part(0, 16)
    |> Base.encode64()
  end

  @doc "Whether `stamp` is the stamp of the PIN as it is now."
  @spec granted?(term()) :: boolean()
  def granted?(stamp) when is_binary(stamp), do: Plug.Crypto.secure_compare(stamp, stamp())
  def granted?(_stamp), do: false

  defp secret, do: NunkiWeb.Endpoint.config(:secret_key_base) || ""

  # --- changing --------------------------------------------------------------

  @doc """
  Makes `pin` the PIN, if the rules allow, and drops the open sockets of
  remote browsers (their grants are void by the stamp already).
  """
  @spec set(term()) :: :ok | {:error, reason()}
  def set(pin) do
    with :ok <- validate(pin),
         :ok <- store(pin) do
      drop_sockets()
      :ok
    end
  end

  @doc "A new random 6-digit PIN, in force; returned so that it can be shown."
  @spec regenerate() :: String.t()
  def regenerate do
    pin = random()
    store_anyway(pin)
    drop_sockets()
    pin
  end

  @doc "6 random digits: 64 random bits taken mod 10^6 (the bias is below 10^-13)."
  def random do
    <<n::unsigned-64>> = :crypto.strong_rand_bytes(8)
    n |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
  end

  @doc "The `live_socket_id` of a remote browser's session, and the topic that closes it."
  def socket_id, do: @topic

  defp drop_sockets do
    NunkiWeb.Endpoint.broadcast(@topic, "disconnect", %{})
  catch
    # No endpoint yet (start-up): there are no sockets to drop.
    _kind, _reason -> :ok
  end

  # --- the file --------------------------------------------------------------

  # Writes the file, and only then puts the PIN in force. A file that cannot
  # be written leaves the PIN as it was, and says so.
  defp store(pin) do
    with :ok <- write_file(pin) do
      :persistent_term.put(@key, pin)
    end
  end

  # For start-up and "a new random one": there is no old PIN worth keeping
  # over a full disk, so the new one holds in memory even when the file
  # cannot be written (until the next restart, which says so in the log).
  defp store_anyway(pin) do
    with {:error, _write} <- write_file(pin) do
      Logger.warning(
        "The access PIN could not be written to #{@file_name}; it holds until Nunki restarts."
      )
    end

    :persistent_term.put(@key, pin)
    :ok
  end

  defp read_file do
    path = path()

    case File.lstat(path) do
      {:error, :enoent} ->
        {:error, :missing}

      {:ok, %File.Stat{type: :regular}} ->
        with {:ok, content} <- File.read(path),
             # A line ending from a Windows editor is not part of the PIN.
             pin = content |> String.replace_suffix("\n", "") |> String.replace_suffix("\r", ""),
             :ok <- validate(pin) do
          {:ok, pin}
        else
          _unusable -> {:error, :unusable}
        end

      _symlink_or_worse ->
        {:error, :unusable}
    end
  end

  # `access-pin.new` is made empty and exclusively (a symlink in its place is
  # an error, not a path to follow), set to 0600 before the PIN goes in, and
  # renamed over the real file. A symlink at the real name is removed first.
  defp write_file(pin) do
    path = path()
    tmp = path <> ".new"

    File.rm(tmp)
    if match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path)), do: File.rm(path)

    with {:ok, io} <- File.open(tmp, [:write, :exclusive, :binary]) do
      written =
        try do
          with :ok <- File.chmod(tmp, 0o600),
               :ok <- IO.binwrite(io, pin <> "\n") do
            :file.sync(io)
          end
        after
          File.close(io)
        end

      with :ok <- written,
           :ok <- File.rename(tmp, path) do
        :ok
      else
        _failed ->
          File.rm(tmp)
          {:error, :write}
      end
    else
      _no_file -> {:error, :write}
    end
  end

  # --- the box's request -----------------------------------------------------

  @doc """
  Applies `<data>/pin-request`, if there is one, and deletes it. `:none`
  without one, else `:set`, `:new` or `{:refused, reason}`. Only a regular
  file is read; anything else is deleted and refused.
  """
  @spec consume_request() :: :none | :set | :new | {:refused, atom()}
  def consume_request do
    path = Path.join(Nunki.Paths.data(), @request_name)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        result = path |> File.read() |> apply_request()
        File.rm(path)
        report(result)
        result

      {:ok, _symlink_or_worse} ->
        File.rm(path)
        report({:refused, :not_a_plain_file})
        {:refused, :not_a_plain_file}

      {:error, _no_file} ->
        :none
    end
  end

  defp apply_request({:ok, content}) do
    case content |> String.replace("\r\n", "\n") |> String.split("\n") do
      ["new" | rest] when rest in [[], [""]] ->
        store_anyway(random())
        :new

      ["set", pin | rest] when rest in [[], [""]] ->
        case validate(pin) do
          :ok ->
            store_anyway(pin)
            :set

          {:error, reason} ->
            {:refused, reason}
        end

      _anything_else ->
        {:refused, :unreadable}
    end
  end

  defp apply_request({:error, _reason}), do: {:refused, :unreadable}

  defp report(:set), do: Logger.info("Access PIN set from the request file.")
  defp report(:new), do: Logger.info("New random access PIN made from the request file.")

  defp report({:refused, reason}),
    do: Logger.warning("Access PIN request refused (#{reason}); the request file is gone.")
end
