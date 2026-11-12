defmodule UniversalProxy.Cec do
  @moduledoc """
  Public API for HDMI-CEC control of whatever sits on the far end of a Pi's
  HDMI link — in practice the AV receiver that carries the HDMI audio output.

  Backed by `BodgeCEC`: one process per adapter talking to `/dev/cecN`
  through the kernel's CEC ioctls (no cec-ctl). `UniversalProxy.Cec.Server`
  discovers the adapters, keeps those processes running and tracks the
  `receiver` state from bus traffic. Adapters are identified by their device
  path (`"/dev/cec0"`); `list_adapters/0` shows which ALSA card (hence which
  Sendspin output) each one belongs to.

  Every function degrades to a harmless default when the subsystem is off
  (host, `enabled: false`, or not started yet) — the project's `catch :exit`
  idiom. Commands run in the caller's process against the adapter process;
  the Server is only consulted for the adapter record. Failures are
  `BodgeCEC`'s typed errors (`:nack` for an absent device, `:timeout` for no
  reply, `{:feature_abort, reason}`, ...).

  Typical IEx session on a Pi:

      UniversalProxy.Cec.list_adapters()
      UniversalProxy.Cec.power_status("/dev/cec0")   #=> {:ok, :standby}
      UniversalProxy.Cec.one_touch_play("/dev/cec0") #=> :ok  (receiver wakes, selects our input)
      UniversalProxy.Cec.volume_up("/dev/cec0")
      UniversalProxy.Cec.standby("/dev/cec0")
  """

  require Logger

  alias UniversalProxy.Cec.Server

  @type dev :: String.t()
  @type power :: :on | :standby | :to_on | :to_standby | :unknown

  @powers [:on, :standby, :to_on, :to_standby]

  # Remote-control keys by their short names, in BodgeCEC's terms (CEC 1.4
  # table 27). Any other `BodgeCEC.Message.ui_commands/0` key or raw byte
  # passes through.
  @keys %{
    volume_up: :volume_up,
    volume_down: :volume_down,
    mute: :mute,
    power_on: :power_on_function,
    power_off: :power_off_function
  }

  @doc "All CEC adapters with what is known about them and their receiver."
  @spec list_adapters() :: [Server.adapter()]
  def list_adapters do
    Server.list_adapters()
  catch
    :exit, _ -> []
  end

  @doc "One adapter by device path."
  @spec get_adapter(dev()) :: {:ok, Server.adapter()} | :error
  def get_adapter(dev) when is_binary(dev) do
    Server.get_adapter(dev)
  catch
    :exit, _ -> :error
  end

  @doc "True when the subsystem is running."
  @spec available?() :: boolean()
  def available?, do: Process.whereis(Server) != nil

  @doc """
  One Touch Play: Image View On to the TV address, then broadcast Active
  Source with our physical address. Wakes a receiver or TV in standby and
  switches it to the Pi's HDMI input. Active Source is skipped while the
  link reports no valid physical address (cable unplugged / EDID not read).
  """
  @spec one_touch_play(dev() | Server.adapter(), keyword()) :: :ok | {:error, term()}
  def one_touch_play(dev_or_adapter, opts \\ []) do
    with {:ok, adapter, cec, _la} <- resolve(dev_or_adapter, opts),
         :ok <- command(fn -> cec.image_view_on(handle(adapter)) end) do
      active_source(adapter, cec)
    end
  end

  defp active_source(adapter, cec) do
    if valid_phys_addr?(adapter.phys_addr) do
      case command(fn -> cec.active_source(handle(adapter)) end) do
        :ok -> :ok
        {:error, reason} -> {:error, {:active_source, reason}}
      end
    else
      Logger.info("CEC: no physical address on #{adapter.dev}; sent Image View On only")
      :ok
    end
  end

  @doc "Put the receiver into standby (directed, not the broadcast that would also hit the TV)."
  @spec standby(dev(), keyword()) :: :ok | {:error, term()}
  def standby(dev, opts \\ []) do
    with {:ok, adapter, cec, la} <- resolve(dev, opts),
         :ok <- command(fn -> cec.standby(handle(adapter), la) end) do
      Server.note_receiver(adapter.dev, %{power: :to_standby})
      :ok
    end
  end

  @doc "Ask the receiver for its power state; also recorded on the adapter."
  @spec power_status(dev(), keyword()) :: {:ok, power()} | {:error, term()}
  def power_status(dev, opts \\ []) do
    with {:ok, adapter, cec, la} <- resolve(dev, opts),
         {:ok, status} <- command(fn -> cec.give_device_power_status(handle(adapter), la) end) do
      power = power_from_report(status)
      Server.note_receiver(adapter.dev, %{power: power})
      {:ok, power}
    end
  end

  @doc "Ask the receiver for its volume (0..100, or nil if it won't say) and mute state."
  @spec audio_status(dev(), keyword()) ::
          {:ok, %{volume: 0..100 | nil, muted: boolean()}} | {:error, term()}
  def audio_status(dev, opts \\ []) do
    with {:ok, adapter, cec, la} <- resolve(dev, opts),
         {:ok, %{muted: muted, volume: volume}} <-
           command(fn -> cec.give_audio_status(handle(adapter), la) end) do
      status = %{volume: volume_from_report(volume), muted: muted}
      Server.note_receiver(adapter.dev, status)
      {:ok, status}
    end
  end

  @doc "One volume-up key press on the receiver."
  @spec volume_up(dev(), keyword()) :: :ok | {:error, term()}
  def volume_up(dev, opts \\ []), do: user_control(dev, :volume_up, opts)

  @doc "One volume-down key press on the receiver."
  @spec volume_down(dev(), keyword()) :: :ok | {:error, term()}
  def volume_down(dev, opts \\ []), do: user_control(dev, :volume_down, opts)

  @doc "Toggle the receiver's mute."
  @spec mute(dev(), keyword()) :: :ok | {:error, term()}
  def mute(dev, opts \\ []), do: user_control(dev, :mute, opts)

  @doc """
  Send one remote-control key (press and release) to the receiver:
  `:volume_up | :volume_down | :mute | :power_on | :power_off`, any other
  `BodgeCEC.Message.ui_commands/0` key, or a raw key byte.
  """
  @spec user_control(dev() | Server.adapter(), atom() | 0..255, keyword()) ::
          :ok | {:error, term()}
  def user_control(dev_or_adapter, key, opts \\ []) do
    with {:ok, adapter, cec, la} <- resolve(dev_or_adapter, opts) do
      command(fn -> cec.user_control(handle(adapter), la, Map.get(@keys, key, key)) end)
    end
  end

  @doc false
  @spec power_from_report(term()) :: power()
  def power_from_report(status) when status in @powers, do: status
  def power_from_report(_other), do: :unknown

  @doc false
  @spec volume_from_report(term()) :: 0..100 | nil
  def volume_from_report(volume) when is_integer(volume) and volume in 0..100, do: volume
  def volume_from_report(_other), do: nil

  # ── private ───────────────────────────────────────────────────────────

  # Server.handle_info passes the adapter it already holds (plus its cec
  # module) so the auto-wake task never calls back into the Server.
  defp resolve(%{dev: _} = adapter, opts) do
    {:ok, adapter, Keyword.get(opts, :cec, cec_module()), Keyword.get(opts, :receiver_la, 5)}
  end

  defp resolve(dev, opts) when is_binary(dev) do
    case Server.get_adapter(dev) do
      {:ok, adapter} ->
        la = Keyword.get_lazy(opts, :receiver_la, fn -> Server.receiver_la() end)
        {:ok, adapter, Keyword.get(opts, :cec, cec_module()), la}

      :error ->
        {:error, :no_such_adapter}
    end
  catch
    :exit, _ -> {:error, :cec_unavailable}
  end

  defp handle(adapter), do: Server.adapter_name(adapter.dev)

  # An adapter process that is gone (node unplugged, open failed) answers
  # with an exit; make that an error like any other.
  defp command(fun) do
    fun.()
  catch
    :exit, {:noproc, _} -> {:error, :adapter_down}
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, {:adapter_exit, reason}}
  end

  # An unplugged HDMI link reports the invalid physical address f.f.f.f.
  defp valid_phys_addr?(pa), do: is_binary(pa) and pa != "f.f.f.f"

  defp cec_module do
    :universal_proxy
    |> Application.get_env(UniversalProxy.Cec, [])
    |> Keyword.get(:cec_module, BodgeCEC)
  end
end
