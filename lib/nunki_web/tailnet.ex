defmodule NunkiWeb.Tailnet do
  @moduledoc """
  This machine's own names and addresses on a Tailscale network, for
  `NunkiWeb.HostGuard`, so that a page opened as
  `http://hall-pi.example-tailnet.ts.net:4062` or `http://100.101.102.103:4062`
  is answered.

  Tailscale comes up when it likes, often after Nunki, and its name can
  change while Nunki runs (a renamed machine, a tailnet joined later). So
  this asks the local Tailscale daemon - `tailscale status --json
  --peers=false`, which describes this machine and nobody else - at the
  start and every 15 seconds, and keeps the answer where a request can
  read it without waiting (`names/0`). Only while Nunki listens on the
  network (`NUNKI_LISTEN=lan`); on loopback there is nobody on the tailnet
  to answer, and no `tailscale` command is run.

  What is taken: `Self.DNSName` (the MagicDNS name, its trailing dot
  removed), `Self.HostName`, and `Self.TailscaleIPs`. Never a peer's, never
  a pattern: a name somebody else's DNS can point at 127.0.0.1 is exactly
  what `HostGuard` is there to refuse, and "anything ending in .ts.net"
  would be such a name. (The interface addresses themselves are read by
  `HostGuard` at every request anyway; the IPs here are for Tailscale in
  userspace mode, which has no interface.)

  No `tailscale` command, a daemon that is not running, a timeout: no names,
  and the log stays quiet about it - a hall without Tailscale is the usual
  case, not an error.
  """
  use GenServer

  @every_ms 15_000
  @key {__MODULE__, :names}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The tailnet names and addresses of this machine, as last seen (lowercase)."
  @spec names() :: [String.t()]
  def names, do: :persistent_term.get(@key, [])

  @doc false
  # For the tests: what `tailscale status` would have said.
  def put_names(names), do: :persistent_term.put(@key, Enum.map(names, &String.downcase/1))

  @doc "Asks Tailscale now and waits for the answer (the timer does this by itself)."
  def refresh, do: GenServer.call(__MODULE__, :refresh, 10_000)

  @doc """
  The names and addresses in a `tailscale status --json` answer, from its
  `Self` and nothing else.
  """
  @spec from_status(term()) :: [String.t()]
  def from_status(%{"Self" => %{} = self}) do
    dns =
      case self["DNSName"] do
        name when is_binary(name) -> [String.trim_trailing(name, ".")]
        _none -> []
      end

    host = if is_binary(self["HostName"]), do: [self["HostName"]], else: []
    ips = for ip when is_binary(ip) <- List.wrap(self["TailscaleIPs"]), do: ip

    (dns ++ host ++ ips)
    |> Enum.map(&String.downcase/1)
    |> Enum.filter(&valid_host?/1)
    |> Enum.uniq()
  end

  def from_status(_other), do: []

  # A host name or an address, nothing that could be read as anything else.
  defp valid_host?(host), do: host != "" and host =~ ~r/\A[a-z0-9.:\-]+\z/

  # --- the process -----------------------------------------------------------------

  @impl true
  def init(_opts) do
    if Application.get_env(:nunki, :tailnet, true), do: send(self(), :refresh)
    {:ok, %{}}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    look()
    {:reply, names(), state}
  end

  @impl true
  def handle_info(:refresh, state) do
    look()
    Process.send_after(self(), :refresh, @every_ms)
    {:noreply, state}
  end

  defp look do
    names =
      with :lan <- Application.get_env(:nunki, :listen),
           exe when is_binary(exe) <- System.find_executable("tailscale"),
           {out, 0} <- Nunki.Cmd.run(exe, ["status", "--json", "--peers=false"], timeout: 5_000),
           {:ok, status} <- Jason.decode(out) do
        from_status(status)
      else
        _nothing -> []
      end

    if names != names(), do: :persistent_term.put(@key, names)
  catch
    _kind, _reason -> :ok
  end
end
