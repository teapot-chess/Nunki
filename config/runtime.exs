import Config

# Runtime configuration: read when the application starts, in every
# environment, also inside a release.

if System.get_env("PHX_SERVER") do
  config :nunki, NunkiWeb.Endpoint, server: true
end

# Where everything is kept. No environment variable is required: a program
# that has to be configured before it starts is a program that does not
# start in a playing hall. `Nunki.DataHome` says where an installed copy
# keeps it and why that is never a folder an installer owns.
data_dir =
  cond do
    data = System.get_env("NUNKI_DATA") -> Path.expand(data)
    config_env() == :prod -> Path.expand(Nunki.DataHome.default())
    true -> nil
  end

# Who may open the pages: this machine (the default), or the hall's network
# as well (NUNKI_LISTEN=lan; an arbiter's laptop starting the countdown from
# across the room). There is always an access PIN (`Nunki.AccessPin`, shown on
# Nunki's own control page): with lan, every other computer is asked for it,
# before any page, the hall screen included.
lan? = System.get_env("NUNKI_LISTEN") == "lan"
listen = if lan?, do: {0, 0, 0, 0}, else: {127, 0, 0, 1}

# `NunkiWeb.HostGuard` adds this machine's names and addresses to the hosts it
# answers to only when Nunki was told to listen on the network.
config :nunki, listen: if(lan?, do: :lan, else: :loopback)

if config_env() != :test do
  config :nunki, NunkiWeb.Endpoint,
    http: [ip: listen, port: String.to_integer(System.get_env("PORT", "4062"))]
end

# The machine's own voice in development, when asked for. Production always
# has it (no voice_backend set means: the one for this system).
if config_env() == :dev and System.get_env("NUNKI_VOICE") == "os" do
  config :nunki, voice_backend: nil
end

if data_dir do
  config :nunki, data_dir: data_dir
end

if config_env() == :dev do
  config :nunki, NunkiWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        ~r"priv/gettext/.*\.po$"E,
        ~r"priv/manual/.*\.md$"E,
        ~r"lib/nunki_web/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  data = data_dir

  # Refused before anything is written there: data inside a folder that an
  # update replaces or an uninstall removes is data with a date on it.
  if reason = Nunki.DataHome.refusal(data) do
    raise Nunki.DataHome.refusal_message(data, reason)
  end

  File.mkdir_p!(data)

  # The cookie-signing secret is made once and kept beside the data.
  secret_file = Path.join(data, "secret_key_base")

  secret =
    System.get_env("SECRET_KEY_BASE") ||
      case File.read(secret_file) do
        {:ok, secret} when byte_size(secret) >= 64 ->
          String.trim(secret)

        _missing ->
          secret = 48 |> :crypto.strong_rand_bytes() |> Base.encode64()
          # Empty and private first, the secret after: it is never in a file
          # anybody else may read, not even for a moment.
          File.write!(secret_file, "")
          File.chmod(secret_file, 0o600)
          File.write!(secret_file, secret)
          secret
      end

  config :nunki, NunkiWeb.Endpoint,
    url: [host: System.get_env("PHX_HOST") || "localhost"],
    secret_key_base: secret
end
