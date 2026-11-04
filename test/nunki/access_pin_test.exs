defmodule Nunki.AccessPinTest do
  @moduledoc """
  The access PIN's file: generation, the rules a PIN must meet, the box's
  `pin-request`, and what a change does to the stamp.
  """

  use Nunki.Case, async: false

  alias Nunki.AccessPin

  # Each test gets a data directory of its own, so the files can be made and
  # unmade at will; the running application's directory comes back after.
  setup do
    dir = Path.join(System.tmp_dir!(), "nunki-pin-#{System.unique_integer([:positive])}")
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

  defp file(dir), do: Path.join(dir, "access-pin")
  defp request(dir), do: Path.join(dir, "pin-request")

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  describe "generation" do
    test "the first start makes six digits, in a file only the owner reads", %{dir: dir} do
      assert :ok = AccessPin.startup()
      pin = AccessPin.current()

      assert pin =~ ~r/\A[0-9]{6}\z/
      assert File.read!(file(dir)) == pin <> "\n"
      unless match?({:win32, _}, :os.type()), do: assert(mode(file(dir)) == 0o600)
      refute File.exists?(file(dir) <> ".new")
    end

    test "a restart keeps the PIN", %{dir: dir} do
      File.write!(file(dir), "135790\n")
      AccessPin.startup()
      assert AccessPin.current() == "135790"
      :persistent_term.erase({AccessPin, :pin})
      assert AccessPin.current() == "135790"
    end

    test "a file with something unusable in it is replaced", %{dir: dir} do
      File.write!(file(dir), "12\n")
      AccessPin.startup()
      assert AccessPin.current() =~ ~r/\A[0-9]{6}\z/
      assert File.read!(file(dir)) == AccessPin.current() <> "\n"
    end

    test "the random ones are digits, and not all the same" do
      pins = for _ <- 1..50, do: AccessPin.random()
      assert Enum.all?(pins, &(&1 =~ ~r/\A[0-9]{6}\z/))
      assert length(Enum.uniq(pins)) > 1
    end

    test "a symlink at the file is never followed", %{dir: dir} do
      target = Path.join(dir, "elsewhere")
      File.write!(target, "keep me")

      case File.ln_s(target, file(dir)) do
        :ok ->
          AccessPin.startup()
          assert File.read!(target) == "keep me"
          assert {:ok, %File.Stat{type: :regular}} = File.lstat(file(dir))

        {:error, _no_symlinks_here} ->
          :ok
      end
    end
  end

  describe "the rules" do
    test "six to sixty-four characters" do
      assert {:error, :too_short} = AccessPin.validate("12345")
      assert :ok = AccessPin.validate("123456")
      assert :ok = AccessPin.validate(String.duplicate("x", 64))
      assert {:error, :too_long} = AccessPin.validate(String.duplicate("x", 65))
      assert {:error, :too_short} = AccessPin.validate("")
      assert {:error, :too_short} = AccessPin.validate(nil)
    end

    test "characters are counted, not bytes" do
      assert {:error, :too_short} = AccessPin.validate("éééée")
      assert :ok = AccessPin.validate("éééééé")
    end

    test "no space at either end, spaces inside are fine" do
      assert {:error, :padded} = AccessPin.validate(" 123456")
      assert {:error, :padded} = AccessPin.validate("123456 ")
      assert :ok = AccessPin.validate("1234 56")
    end

    test "nothing invisible" do
      assert {:error, :control} = AccessPin.validate("12\u000034567")
      assert {:error, :control} = AccessPin.validate("12\t3456")
      assert {:error, :control} = AccessPin.validate("12\u007f3456")
      assert {:error, :control} = AccessPin.validate("12\u00853456")
      assert {:error, :invalid_utf8} = AccessPin.validate(<<255, 254, 253, 252, 251, 250>>)
    end

    test "a refused change leaves the PIN as it was" do
      before = AccessPin.current()
      assert {:error, :too_short} = AccessPin.set("1")
      assert AccessPin.current() == before
    end

    test "a good change is written, in force, and the file is private", %{dir: dir} do
      assert :ok = AccessPin.set("my own pin")
      assert AccessPin.current() == "my own pin"
      assert File.read!(file(dir)) == "my own pin\n"
      unless match?({:win32, _}, :os.type()), do: assert(mode(file(dir)) == 0o600)
    end

    test "a guess is compared whole" do
      AccessPin.set("246810")
      assert AccessPin.valid_guess?("246810")
      refute AccessPin.valid_guess?("24681")
      refute AccessPin.valid_guess?("2468100")
      refute AccessPin.valid_guess?(nil)
    end
  end

  describe "the stamp" do
    test "is not the PIN, and moves with it" do
      AccessPin.set("246810")
      stamp = AccessPin.stamp()
      refute stamp =~ "246810"
      assert AccessPin.granted?(stamp)

      AccessPin.set("135790")
      refute AccessPin.granted?(stamp)
      assert AccessPin.granted?(AccessPin.stamp())

      AccessPin.regenerate()
      refute AccessPin.granted?(stamp)
    end

    test "nothing is a grant" do
      refute AccessPin.granted?(nil)
      refute AccessPin.granted?("")
      refute AccessPin.granted?(true)
    end

    test "a change tells the sockets to go" do
      NunkiWeb.Endpoint.subscribe(AccessPin.socket_id())
      AccessPin.set("135790")
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      AccessPin.regenerate()
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end
  end

  describe "the box's pin-request" do
    test "set, with a good PIN", %{dir: dir} do
      File.write!(request(dir), "set\nbox chose this\n")
      assert :set = AccessPin.consume_request()
      assert AccessPin.current() == "box chose this"
      assert File.read!(file(dir)) == "box chose this\n"
      refute File.exists?(request(dir))
    end

    test "set, with a bad PIN, is refused and the PIN stays", %{dir: dir} do
      before = AccessPin.current()
      File.write!(request(dir), "set\n123\n")
      assert {:refused, :too_short} = AccessPin.consume_request()
      assert AccessPin.current() == before
      refute File.exists?(request(dir))
    end

    test "new makes a fresh random PIN", %{dir: dir} do
      before = AccessPin.current()
      File.write!(request(dir), "new\n")
      assert :new = AccessPin.consume_request()
      assert AccessPin.current() =~ ~r/\A[0-9]{6}\z/
      assert File.read!(file(dir)) == AccessPin.current() <> "\n"
      refute File.exists?(request(dir))
      assert before != nil
    end

    test "remove is refused: there is always a PIN", %{dir: dir} do
      before = AccessPin.current()
      File.write!(request(dir), "remove\n")
      assert {:refused, :unreadable} = AccessPin.consume_request()
      assert AccessPin.current() == before
      refute File.exists?(request(dir))
    end

    test "garbage is refused and deleted", %{dir: dir} do
      before = AccessPin.current()

      for junk <- ["", "set", "set\n", "set\nabcdef\nextra\n", "NEW\n", "new\nmore\n", "\n\n"] do
        File.write!(request(dir), junk)
        assert {:refused, _reason} = AccessPin.consume_request(), inspect(junk)
        refute File.exists?(request(dir))
      end

      assert AccessPin.current() == before
    end

    test "a symlink is not read, only removed", %{dir: dir} do
      target = Path.join(dir, "elsewhere")
      File.write!(target, "set\nfrom the link\n")
      before = AccessPin.current()

      case File.ln_s(target, request(dir)) do
        :ok ->
          assert {:refused, :not_a_plain_file} = AccessPin.consume_request()
          assert AccessPin.current() == before
          refute File.exists?(request(dir))
          assert File.exists?(target)

        {:error, _no_symlinks_here} ->
          :ok
      end
    end

    test "nothing to do without one" do
      assert :none = AccessPin.consume_request()
    end

    test "the start-up step applies it before it makes a PIN of its own", %{dir: dir} do
      File.write!(request(dir), "set\nstarted with this\n")
      AccessPin.startup()
      assert AccessPin.current() == "started with this"
    end
  end
end
