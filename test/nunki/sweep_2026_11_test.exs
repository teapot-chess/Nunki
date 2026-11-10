defmodule Nunki.Sweep202611Test do
  @moduledoc "The fixes of the 2026-11 sweep that have no better home."

  use Nunki.Case, async: false

  alias Nunki.{AccessPin, Announcer, Store, Updates, Voice}

  @root Path.expand("../..", __DIR__)

  defp read(path), do: File.read!(Path.join(@root, path))

  describe "the access PIN file" do
    setup do
      dir = Path.join(System.tmp_dir!(), "nunki-sweep-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      old = Application.fetch_env!(:nunki, :data_dir)
      Application.put_env(:nunki, :data_dir, dir)

      on_exit(fn ->
        Application.put_env(:nunki, :data_dir, old)
        AccessPin.load()
        File.rm_rf(dir)
      end)

      {:ok, dir: dir}
    end

    test "a PIN typed in an editor that ends lines with CRLF is the PIN", %{dir: dir} do
      File.write!(Path.join(dir, "access-pin"), "246810\r\n")
      AccessPin.startup()
      assert AccessPin.current() == "246810"
    end

    test "a PIN that cannot be written is an error, and the old one stays", %{dir: dir} do
      AccessPin.startup()
      old = AccessPin.current()
      # A folder where the temporary file goes: nothing can be written there.
      File.mkdir_p!(Path.join(dir, "access-pin.new"))

      assert {:error, :write} = AccessPin.set("a-new-pin-123")
      assert AccessPin.current() == old
    end
  end

  test "a PIN is not written to the log, whatever the level" do
    assert read("config/config.exs") =~ ~s("secret", "pin")
  end

  describe "the Linux scripts" do
    test "no longer say there is no PIN, and show where it is" do
      install = read("rel/linux/install.sh")
      refute install =~ "no PIN"
      refute install =~ "There is no PIN"
      assert install =~ "access-pin"
      assert install =~ "Access PIN:"
      assert read("README.md") =~ "sudo cat /var/lib/nunki/access-pin"
    end

    test "the updater follows no symlink the service user could have planted" do
      update = read("rel/linux/update.sh")
      assert update =~ ~s([ ! -L "$DATA_DIR/state.json" ])
      assert update =~ ~s([ -L "$DATA_DIR/backups" ])
      assert update =~ "--no-dereference"
      assert update =~ "chown -R -h"
    end
  end

  describe "the update status" do
    setup do
      path = Path.join(System.tmp_dir!(), "nunki-status-#{System.unique_integer([:positive])}")
      Application.put_env(:nunki, :update_status_file, path)

      on_exit(fn ->
        Application.delete_env(:nunki, :update_status_file)
        File.rm(path)
      end)

      {:ok, path: path}
    end

    test "an answer older than the request is not the answer", %{path: path} do
      File.write!(path, "failed 1.2.3 the download did not succeed\n")
      now = System.os_time(:second)

      assert {:failed, "1.2.3", "the download did not succeed"} =
               Updates.last_result_since(now - 5)

      assert Updates.last_result_since(now + 3600) == nil
    end

    test "no file, no answer" do
      assert Updates.last_result_since(0) == nil
    end
  end

  describe "a round from the server" do
    defp joined do
      {:ok, id} =
        Store.add_tournament(%{
          "server" => "fake",
          "socket" => "ws://127.0.0.1:1/p/nunki/link",
          "key" => "k",
          "tournament" => %{"id" => "t-1", "name" => "Fake Open"}
        })

      id
    end

    test "with boards that are not boards is skipped, not stored" do
      id = joined()

      for boards <- ["nope", [%{"board" => %{"x" => 1}}], [7]] do
        assert Announcer.round_received(id, %{"round" => 3, "boards" => boards}) == :kept
        assert Store.tournament(id)["round"] == nil
      end
    end
  end

  test "a reading stopped by force leaves no sound file behind" do
    dir = Path.join(System.tmp_dir!(), "nunki-wav-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    txt = Path.join(dir, "say-1.txt")
    wav = Path.join(dir, "say-1.wav")
    File.write!(txt, "x")
    File.write!(wav, "x")

    Voice.finished(%{file: txt})
    refute File.exists?(txt)
    refute File.exists?(wav)
  end

  test "the secret key base file is made private before the secret goes in" do
    runtime = read("config/runtime.exs")
    {empty, _} = :binary.match(runtime, ~s[File.write!(secret_file, "")])
    {secret, _} = :binary.match(runtime, "File.write!(secret_file, secret)")
    assert empty < secret
  end
end
