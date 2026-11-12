defmodule UniversalProxy.Cec.EnumerateTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Cec.Enumerate

  # Lays out the sysfs shape vc4 produces on a Pi 4: two HDMI platform
  # devices, each with a CEC adapter and an ALSA card pointing at it, plus a
  # headphone card on another device and an adapter with no /dev node. As in
  # real sysfs, `/sys/class/<subsys>/<name>` is a symlink into
  # `/sys/devices/...` and its `device` link is relative to that real
  # directory.
  setup do
    root = Path.join(System.tmp_dir!(), "cec_enum_#{System.unique_integer([:positive])}")
    soc = Path.join(root, "sys/devices/platform/soc")
    cec = Path.join(root, "sys/class/cec")
    sound = Path.join(root, "sys/class/sound")
    dev = Path.join(root, "dev")

    File.mkdir_p!(cec)
    File.mkdir_p!(sound)
    File.mkdir_p!(dev)

    link = fn class_root, name, device_path ->
      subsys = Path.basename(class_root)
      real = Path.join([soc, device_path, subsys, name])
      File.mkdir_p!(real)
      File.ln_s!("../../../#{Path.basename(device_path)}", Path.join(real, "device"))

      File.ln_s!(
        "../../devices/platform/soc/#{device_path}/#{subsys}/#{name}",
        Path.join(class_root, name)
      )
    end

    link.(cec, "cec0", "fef00700.hdmi")
    link.(cec, "cec1", "fef05700.hdmi")
    link.(cec, "cec2", "fe00b840.mailbox")
    link.(sound, "card0", "fe00b840.mailbox/bcm2835-audio")
    link.(sound, "card1", "fef00700.hdmi")
    link.(sound, "card2", "fef05700.hdmi")
    File.touch!(Path.join(dev, "cec0"))
    File.touch!(Path.join(dev, "cec1"))

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, opts: [sys_root: cec, sound_sys_root: sound, dev_root: dev], dev: dev, soc: soc}
  end

  test "pairs each adapter with the ALSA card on the same HDMI device", %{opts: opts, dev: dev} do
    assert Enumerate.list(opts) == %{
             Path.join(dev, "cec0") => %{
               dev: Path.join(dev, "cec0"),
               index: 0,
               hdmi_device: "fef00700.hdmi",
               card_index: 1
             },
             Path.join(dev, "cec1") => %{
               dev: Path.join(dev, "cec1"),
               index: 1,
               hdmi_device: "fef05700.hdmi",
               card_index: 2
             }
           }
  end

  test "an adapter without a /dev node is skipped and a missing sysfs root is empty", %{
    opts: opts
  } do
    refute Map.has_key?(Enumerate.list(opts), Path.join(opts[:dev_root], "cec2"))

    assert Enumerate.list(
             sys_root: "/nonexistent/cec",
             sound_sys_root: "/nonexistent/sound",
             dev_root: "/nonexistent"
           ) == %{}
  end

  test "pairs by the resolved device node, not just its basename", %{
    opts: opts,
    dev: dev,
    soc: soc
  } do
    # A card on a different device that happens to share the HDMI node's
    # basename must not be paired with cec0.
    real = Path.join([soc, "fe9c0000.bus/fef00700.hdmi/sound/card3"])
    File.mkdir_p!(real)
    File.ln_s!("../../../fef00700.hdmi", Path.join(real, "device"))

    File.ln_s!(
      "../../devices/platform/soc/fe9c0000.bus/fef00700.hdmi/sound/card3",
      Path.join(opts[:sound_sys_root], "card3")
    )

    File.rm!(Path.join(opts[:sound_sys_root], "card1"))

    assert %{card_index: nil, hdmi_device: "fef00700.hdmi"} =
             Enumerate.list(opts)[Path.join(dev, "cec0")]
  end

  # What cec-core actually produces (a Pi 4 on the 6.18 kernel): adapters are
  # bus devices, so `/sys/bus/cec/devices/cecN` is a symlink to the adapter
  # directory under the HDMI device and has no `device` link of its own; the
  # HDMI node is the parent of the resolved entry. Sound cards are class
  # entries as above.
  describe "bus layout (/sys/bus/cec/devices)" do
    setup do
      root = Path.join(System.tmp_dir!(), "cec_bus_#{System.unique_integer([:positive])}")
      soc = Path.join(root, "sys/devices/platform/soc")
      bus = Path.join(root, "sys/bus/cec/devices")
      sound = Path.join(root, "sys/class/sound")
      dev = Path.join(root, "dev")

      for d <- [bus, sound, dev], do: File.mkdir_p!(d)

      adapter = fn device_path, name ->
        File.mkdir_p!(Path.join([soc, device_path, name]))
        File.ln_s!("../../../devices/platform/soc/#{device_path}/#{name}", Path.join(bus, name))
      end

      card = fn device_path, name ->
        real = Path.join([soc, device_path, "sound", name])
        File.mkdir_p!(real)
        File.ln_s!("../../../#{Path.basename(device_path)}", Path.join(real, "device"))

        File.ln_s!(
          "../../devices/platform/soc/#{device_path}/sound/#{name}",
          Path.join(sound, name)
        )
      end

      adapter.("fef00700.hdmi", "cec0")
      adapter.("fef05700.hdmi", "cec1")
      card.("fe00b840.mailbox/bcm2835-audio", "card0")
      card.("fef00700.hdmi", "card1")
      card.("fef05700.hdmi", "card2")
      File.touch!(Path.join(dev, "cec0"))
      File.touch!(Path.join(dev, "cec1"))

      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, opts: [sys_root: bus, sound_sys_root: sound, dev_root: dev], dev: dev}
    end

    test "pairs each adapter with its HDMI card through the resolved entry", %{
      opts: opts,
      dev: dev
    } do
      assert Enumerate.list(opts) == %{
               Path.join(dev, "cec0") => %{
                 dev: Path.join(dev, "cec0"),
                 index: 0,
                 hdmi_device: "fef00700.hdmi",
                 card_index: 1
               },
               Path.join(dev, "cec1") => %{
                 dev: Path.join(dev, "cec1"),
                 index: 1,
                 hdmi_device: "fef05700.hdmi",
                 card_index: 2
               }
             }
    end

    test "an entry that is neither a symlink nor has a device link stays unpaired", %{
      opts: opts,
      dev: dev
    } do
      File.mkdir_p!(Path.join(opts[:sys_root], "cec2"))
      File.touch!(Path.join(dev, "cec2"))

      assert %{hdmi_device: nil, card_index: nil} =
               Enumerate.list(opts)[Path.join(dev, "cec2")]
    end
  end

  test "the default root prefers the bus layout, falling back to the class path" do
    assert Enumerate.default_sys_root() in ["/sys/bus/cec/devices", "/sys/class/cec"]
  end
end
