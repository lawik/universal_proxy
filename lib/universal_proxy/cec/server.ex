defmodule UniversalProxy.Cec.Server do
  @moduledoc """
  Owns the CEC adapter inventory: discovers `/dev/cecN`, runs one `BodgeCEC`
  process per adapter (which claims a Playback Device logical address on it
  and answers the bus as a source device), and tracks what is known about
  the device on the other end of each HDMI link (the AV receiver at logical
  address 5, by default).

  Adapter processes live under `UniversalProxy.Cec.AdapterSupervisor` and are
  registered in `UniversalProxy.Cec.AdapterRegistry` by device path
  (`adapter_name/1`), so commands (`UniversalProxy.Cec.one_touch_play/1` and
  friends) reach them by name from the *caller's* process; this server is
  only consulted for the adapter record. A slow receiver therefore never
  blocks this server or the hotplug scan. Each adapter notifies this server
  of its events (received messages, address changes; see `t:BodgeCEC.event/0`),
  which keep the `receiver` state current and are rebroadcast on the
  `"cec:events"` PubSub topic as `{:cec_event, dev, event}`.

  ## Auto-wake

  Subscribed to the Sendspin state topic: a `stream_start` on an output whose
  ALSA card is the one paired with an adapter fires One Touch Play (Image
  View On + Active Source), waking a receiver in standby and switching it to
  the Pi's input before audio hits the link. Off per-install via
  `auto_wake: false` in the `UniversalProxy.Cec` env.

  Dependencies are injectable through `start_link/1` opts so host tests run
  without a CEC adapter or sysfs: `:cec_module` (a `BodgeCEC` stand-in),
  `:enumerate` (a 0-arity fun), `:output_lookup` (key -> `{:ok, %{card_index: n}}`).
  """

  use GenServer

  require Logger

  alias BodgeCEC.PhysicalAddress
  alias UniversalProxy.Cec.Enumerate

  @pubsub UniversalProxy.PubSub
  @audio_topic "sendspin:state"
  @topic "cec:events"
  @default_scan_ms 10_000
  @registry UniversalProxy.Cec.AdapterRegistry
  @adapter_supervisor UniversalProxy.Cec.AdapterSupervisor
  # CEC's <Set OSD Name> carries at most 14 bytes.
  @osd_name_max 14

  @type receiver :: %{
          power: :on | :standby | :to_on | :to_standby | :unknown,
          volume: 0..100 | nil,
          muted: boolean() | nil,
          updated_at: DateTime.t() | nil
        }

  @type adapter :: %{
          dev: String.t(),
          index: non_neg_integer(),
          hdmi_device: String.t() | nil,
          card_index: non_neg_integer() | nil,
          phys_addr: String.t() | nil,
          logical_address: 0..15 | nil,
          claimed?: boolean(),
          receiver: receiver()
        }

  defstruct adapters: %{},
            cec: BodgeCEC,
            enumerate: nil,
            output_lookup: nil,
            osd_name: "UniversalProxy",
            auto_wake: true,
            receiver_la: 5,
            scan_ms: @default_scan_ms,
            pubsub: @pubsub,
            task_sup: UniversalProxy.TaskSupervisor

  # ── API ───────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec list_adapters(GenServer.server()) :: [adapter()]
  def list_adapters(server \\ __MODULE__), do: GenServer.call(server, :list_adapters)

  @spec get_adapter(GenServer.server(), String.t()) :: {:ok, adapter()} | :error
  def get_adapter(server \\ __MODULE__, dev), do: GenServer.call(server, {:get_adapter, dev})

  @doc "Adapter paired with an ALSA card index (via the shared HDMI sysfs node)."
  @spec adapter_for_card(GenServer.server(), non_neg_integer()) :: {:ok, adapter()} | :error
  def adapter_for_card(server \\ __MODULE__, card_index),
    do: GenServer.call(server, {:adapter_for_card, card_index})

  @doc "Record something learned about the far end (from a request's reply)."
  @spec note_receiver(GenServer.server(), String.t(), map()) :: :ok
  def note_receiver(server \\ __MODULE__, dev, partial) when is_map(partial),
    do: GenServer.cast(server, {:note_receiver, dev, partial})

  @doc "Re-run discovery now (tests, or after a manual cable swap)."
  @spec rescan(GenServer.server()) :: :ok
  def rescan(server \\ __MODULE__), do: GenServer.call(server, :rescan)

  @doc "Receiver logical address commands are sent to."
  @spec receiver_la(GenServer.server()) :: 0..15
  def receiver_la(server \\ __MODULE__), do: GenServer.call(server, :receiver_la)

  @doc """
  Registered name of the adapter process for a device path: what the
  `BodgeCEC` functions take as their adapter argument.
  """
  @spec adapter_name(String.t()) :: GenServer.name()
  def adapter_name(dev) when is_binary(dev), do: {:via, Registry, {@registry, dev}}

  @doc "PubSub topic adapter events are rebroadcast on, as `{:cec_event, dev, event}`."
  @spec topic() :: String.t()
  def topic, do: @topic

  # ── GenServer ─────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    env = Application.get_env(:universal_proxy, UniversalProxy.Cec, [])
    get = fn key, default -> Keyword.get(opts, key, Keyword.get(env, key, default)) end

    state = %__MODULE__{
      cec: get.(:cec_module, BodgeCEC),
      enumerate: Keyword.get(opts, :enumerate, &Enumerate.list/0),
      output_lookup: Keyword.get(opts, :output_lookup, &UniversalProxy.Audio.get_output/1),
      osd_name: osd_name(get.(:osd_name, "UniversalProxy")),
      auto_wake: get.(:auto_wake, true),
      receiver_la: get.(:receiver_la, 5),
      scan_ms: get.(:scan_interval_ms, @default_scan_ms),
      pubsub: Keyword.get(opts, :pubsub, @pubsub),
      task_sup: Keyword.get(opts, :task_supervisor, UniversalProxy.TaskSupervisor)
    }

    Phoenix.PubSub.subscribe(state.pubsub, @audio_topic)
    send(self(), :scan)
    {:ok, state}
  end

  @impl true
  def handle_call(:list_adapters, _from, state) do
    {:reply, state.adapters |> Map.values() |> Enum.sort_by(& &1.index), state}
  end

  def handle_call({:get_adapter, dev}, _from, state),
    do: {:reply, Map.fetch(state.adapters, dev), state}

  def handle_call({:adapter_for_card, card_index}, _from, state) do
    {:reply, find_by_card(state, card_index), state}
  end

  def handle_call(:rescan, _from, state), do: {:reply, :ok, scan(state)}
  def handle_call(:receiver_la, _from, state), do: {:reply, state.receiver_la, state}

  @impl true
  def handle_cast({:note_receiver, dev, partial}, state) do
    {:noreply, update_receiver(state, dev, partial)}
  end

  @impl true
  def handle_info(:scan, state) do
    Process.send_after(self(), :scan, state.scan_ms)
    {:noreply, scan(state)}
  end

  # A Sendspin stream starting on an HDMI output: wake + select the receiver.
  def handle_info({:sendspin_state, key, %{event: "stream_start"}}, state) do
    if state.auto_wake do
      with {:ok, %{card_index: card}} <- state.output_lookup.(key),
           {:ok, adapter} <- find_by_card(state, card) do
        Logger.info("CEC: stream starting on card #{card}; One Touch Play via #{adapter.dev}")
        cec = state.cec
        la = state.receiver_la

        Task.Supervisor.start_child(state.task_sup, fn ->
          case UniversalProxy.Cec.one_touch_play(adapter, cec: cec, receiver_la: la) do
            :ok ->
              Logger.info("CEC: One Touch Play via #{adapter.dev} delivered")

            {:error, reason} ->
              Logger.warning("CEC: One Touch Play via #{adapter.dev} failed: #{inspect(reason)}")
          end
        end)
      end
    end

    {:noreply, state}
  end

  def handle_info({:sendspin_state, _key, _event}, state), do: {:noreply, state}

  # An adapter process reporting; it is known by what it registered as.
  def handle_info({:bodge_cec, pid, event}, state) do
    case Registry.keys(@registry, pid) do
      [dev] ->
        Phoenix.PubSub.broadcast(state.pubsub, @topic, {:cec_event, dev, event})
        {:noreply, apply_event(state, dev, event)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── discovery ─────────────────────────────────────────────────────────

  defp scan(state) do
    present = safe_enumerate(state)
    known = state.adapters

    removed = Map.keys(known) -- Map.keys(present)
    state = Enum.reduce(removed, state, &remove_adapter(&2, &1))

    Enum.reduce(present, state, fn {dev, info}, acc ->
      case Map.fetch(acc.adapters, dev) do
        {:ok, existing} ->
          # Keep what we learned; refresh the sysfs-derived pairing, and
          # reopen an adapter whose process is not running (a failed open
          # last time, or one that stopped on its own).
          ensure_running(acc, %{
            existing
            | hdmi_device: info.hdmi_device,
              card_index: info.card_index
          })

        :error ->
          add_adapter(acc, info)
      end
    end)
  end

  defp safe_enumerate(state) do
    state.enumerate.()
  rescue
    e ->
      Logger.warning("CEC enumerate raised: #{Exception.message(e)}")
      %{}
  end

  defp add_adapter(state, info) do
    adapter =
      Map.merge(info, %{
        phys_addr: nil,
        logical_address: nil,
        claimed?: false,
        receiver: %{power: :unknown, volume: nil, muted: nil, updated_at: nil}
      })

    start_adapter(state, adapter)
  end

  defp ensure_running(state, adapter) do
    case Registry.lookup(@registry, adapter.dev) do
      [] -> start_adapter(state, adapter)
      _ -> put_adapter(state, adapter)
    end
  end

  defp start_adapter(state, adapter) do
    dev = adapter.dev

    case DynamicSupervisor.start_child(@adapter_supervisor, adapter_spec(state, dev)) do
      {:ok, pid} ->
        put_adapter(state, learn_addresses(state, adapter, pid))

      {:error, {:already_started, pid}} ->
        put_adapter(state, learn_addresses(state, adapter, pid))

      {:error, reason} ->
        Logger.warning(
          "CEC: opening #{dev} failed: #{inspect(reason)}; retrying on the next scan"
        )

        put_adapter(state, adapter)
    end
  end

  # The adapter's claim completes asynchronously and arrives as a
  # `:state_change` event too; reading the snapshot now just makes the record
  # complete as soon as discovery returns.
  defp learn_addresses(state, adapter, pid) do
    %{phys_addr: pa, log_addrs: las} = state.cec.info(pid)
    adapter = with_addresses(adapter, pa, las)

    Logger.info(
      "CEC: #{adapter.dev} (#{adapter.hdmi_device || "?"}, card #{inspect(adapter.card_index)}) " <>
        "phys #{inspect(adapter.phys_addr)} logical #{inspect(adapter.logical_address)}"
    )

    adapter
  catch
    :exit, _ -> adapter
  end

  defp with_addresses(adapter, pa, log_addrs) do
    %{
      adapter
      | phys_addr: PhysicalAddress.to_string(pa),
        logical_address: List.first(log_addrs),
        claimed?: log_addrs != []
    }
  end

  defp adapter_spec(state, dev) do
    opts = [
      device: dev,
      name: adapter_name(dev),
      notify: self(),
      claim: [type: :playback, osd_name: state.osd_name]
    ]

    # :transient — an adapter that stops normally (the HDMI driver unbound
    # under it) is not restarted; the scan reopens it when the node is back.
    %{
      id: {:cec_adapter, dev},
      start: {state.cec, :start_link, [opts]},
      restart: :transient,
      shutdown: 5_000
    }
  end

  defp remove_adapter(state, dev) do
    Logger.info("CEC: #{dev} gone")
    stop_adapter(dev)
    %{state | adapters: Map.delete(state.adapters, dev)}
  end

  # A graceful stop: the adapter releases the fd and its follower role in
  # terminate/2 (BodgeCEC must not be brutal-killed).
  defp stop_adapter(dev) do
    case Registry.lookup(@registry, dev) do
      [{pid, _}] -> _ = DynamicSupervisor.terminate_child(@adapter_supervisor, pid)
      [] -> :ok
    end

    :ok
  rescue
    # Registry.lookup/2 raises (not exits) when the registry isn't running.
    ArgumentError -> :ok
  end

  defp osd_name(name) when is_binary(name) and byte_size(name) <= @osd_name_max, do: name

  defp osd_name(name) when is_binary(name) do
    short = binary_part(name, 0, @osd_name_max)

    Logger.warning(
      "CEC: OSD name #{inspect(name)} is over #{@osd_name_max} bytes; using #{inspect(short)}"
    )

    short
  end

  # ── state updates ─────────────────────────────────────────────────────

  defp apply_event(state, dev, {:state_change, %{phys_addr: pa, log_addrs: las}}) do
    update_adapter(state, dev, fn adapter ->
      updated = with_addresses(adapter, pa, las)

      if Map.take(updated, [:phys_addr, :logical_address]) !=
           Map.take(adapter, [:phys_addr, :logical_address]),
         do:
           Logger.info(
             "CEC: #{dev} phys #{inspect(updated.phys_addr)} logical #{inspect(updated.logical_address)}"
           )

      updated
    end)
  end

  defp apply_event(state, dev, {:message, from, to, message}),
    do: apply_message(state, dev, from, to, message)

  defp apply_event(state, _dev, _event), do: state

  # Status reports only describe the receiver when the receiver sent them
  # (a TV answering a power query reports its own state).
  defp apply_message(%{receiver_la: la} = state, dev, la, _to, {:report_power_status, status}),
    do: update_receiver(state, dev, %{power: UniversalProxy.Cec.power_from_report(status)})

  defp apply_message(
         %{receiver_la: la} = state,
         dev,
         la,
         _to,
         {:report_audio_status, muted, vol}
       ),
       do:
         update_receiver(state, dev, %{
           muted: muted,
           volume: UniversalProxy.Cec.volume_from_report(vol)
         })

  # A broadcast Standby puts every device on the bus into standby; a directed
  # one only counts when it comes from the receiver.
  defp apply_message(state, dev, _from, 15, :standby),
    do: update_receiver(state, dev, %{power: :standby})

  defp apply_message(%{receiver_la: la} = state, dev, la, _to, :standby),
    do: update_receiver(state, dev, %{power: :standby})

  defp apply_message(state, _dev, _from, _to, _message), do: state

  defp update_receiver(state, dev, partial) do
    update_adapter(state, dev, fn adapter ->
      receiver =
        adapter.receiver
        |> Map.merge(Map.take(partial, [:power, :volume, :muted]))
        |> Map.put(:updated_at, DateTime.utc_now())

      %{adapter | receiver: receiver}
    end)
  end

  defp update_adapter(state, dev, fun) do
    case Map.fetch(state.adapters, dev) do
      {:ok, adapter} -> put_adapter(state, fun.(adapter))
      :error -> state
    end
  end

  defp put_adapter(state, adapter),
    do: %{state | adapters: Map.put(state.adapters, adapter.dev, adapter)}

  defp find_by_card(_state, nil), do: :error

  defp find_by_card(state, card_index) do
    case Enum.find(Map.values(state.adapters), &(&1.card_index == card_index)) do
      nil -> :error
      adapter -> {:ok, adapter}
    end
  end
end
