defmodule UniversalProxy.Cec.Enumerate do
  @moduledoc """
  Lists the kernel CEC adapters (`/dev/cecN`) and pairs each with the ALSA
  card of the same HDMI port.

  The vc4 driver registers both the CEC adapter and the HDMI ALSA card on the
  HDMI port's platform device (e.g. `fef00700.hdmi` for HDMI0 on a Pi 4).
  That shared node is the pairing key; the resulting `card_index` lines up
  with `UniversalProxy.Audio.Enumerate`'s `:card_index` so a Sendspin output
  can be mapped to its CEC adapter.

  cec-core registers adapters on a bus, not a class, so what a kernel has is
  `/sys/bus/cec/devices/cecN`: a symlink straight to the adapter directory
  under the HDMI device, with no `device` link of its own — the HDMI node is
  the parent of the resolved entry. `/sys/class/cec/cecN` entries with a
  `device` link to the HDMI node are handled as well, and `/sys/class/cec`
  stays the fallback root. Sound cards are class entries whose `device` link
  resolves to the same HDMI node.

  Roots are overridable (`:sys_root`, `:sound_sys_root`, `:dev_root`) for
  host-side tests. Never raises: any failure yields `%{}`.
  """

  require Logger

  @type adapter :: %{
          dev: String.t(),
          index: non_neg_integer(),
          hdmi_device: String.t() | nil,
          card_index: non_neg_integer() | nil
        }

  @cec_re ~r/^cec(\d+)$/
  @card_re ~r/^card(\d+)$/

  # The bus is what cec-core creates; the class path is only a fallback.
  @default_sys_roots ["/sys/bus/cec/devices", "/sys/class/cec"]

  @doc "Adapters keyed by device path, e.g. `%{\"/dev/cec0\" => %{...}}`."
  @spec list(keyword()) :: %{String.t() => adapter()}
  def list(opts \\ []) do
    sys_root = Keyword.get_lazy(opts, :sys_root, &default_sys_root/0)
    sound_root = Keyword.get(opts, :sound_sys_root, "/sys/class/sound")
    dev_root = Keyword.get(opts, :dev_root, "/dev")

    cards = cards_by_device(sound_root)

    sys_root
    |> entries(@cec_re)
    |> Enum.reduce(%{}, fn {name, index}, acc ->
      dev = Path.join(dev_root, name)

      if File.exists?(dev) do
        node = adapter_parent(Path.join(sys_root, name))

        Map.put(acc, dev, %{
          dev: dev,
          index: index,
          hdmi_device: node && Path.basename(node),
          card_index: node && Map.get(cards, node)
        })
      else
        acc
      end
    end)
  rescue
    e ->
      Logger.warning("CEC enumerate failed: #{Exception.format(:error, e, __STACKTRACE__)}")
      %{}
  end

  @doc false
  @spec default_sys_root() :: String.t()
  def default_sys_root do
    Enum.find(@default_sys_roots, &File.dir?/1) || hd(@default_sys_roots)
  end

  defp cards_by_device(sound_root) do
    sound_root
    |> entries(@card_re)
    |> Enum.reduce(%{}, fn {name, index}, acc ->
      case device_node(Path.join(sound_root, name)) do
        nil -> acc
        node -> Map.put_new(acc, node, index)
      end
    end)
  end

  defp entries(root, re) do
    case File.ls(root) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          case Regex.run(re, name) do
            [_, idx] -> [{name, String.to_integer(idx)}]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  # The HDMI platform device an adapter entry belongs to. A class-style entry
  # says so through its `device` link; a bus entry is a symlink to the adapter
  # directory itself, whose parent is the HDMI device. An entry that is
  # neither tells us nothing.
  defp adapter_parent(entry) do
    case device_node(entry) do
      nil ->
        with {:ok, _} <- File.read_link(entry), real when is_binary(real) <- realpath(entry) do
          Path.dirname(real)
        else
          _ -> nil
        end

      node ->
        node
    end
  end

  # Real path of `<class dir>/device`. Class entries are themselves symlinks
  # into `/sys/devices/...` and the `device` link is relative to that real
  # directory, so every component has to be resolved (a lexical
  # `Path.expand/2` lands somewhere else entirely).
  defp device_node(class_dir) do
    link = Path.join(class_dir, "device")

    case File.read_link(link) do
      {:ok, _} -> realpath(link)
      _ -> nil
    end
  end

  @max_links 40

  defp realpath(path) do
    ["/" | parts] = path |> Path.absname() |> Path.split()
    resolve(parts, "/", 0)
  end

  defp resolve([], resolved, _links), do: resolved
  defp resolve(["." | rest], resolved, links), do: resolve(rest, resolved, links)
  defp resolve([".." | rest], resolved, links), do: resolve(rest, Path.dirname(resolved), links)

  defp resolve([part | rest], resolved, links) do
    candidate = Path.join(resolved, part)

    case File.read_link(candidate) do
      {:ok, _target} when links >= @max_links ->
        nil

      {:ok, target} ->
        case Path.split(target) do
          ["/" | parts] -> resolve(parts ++ rest, "/", links + 1)
          parts -> resolve(parts ++ rest, resolved, links + 1)
        end

      {:error, _} ->
        resolve(rest, candidate, links)
    end
  end
end
