defmodule UniversalProxy.Cec.ServerTest do
  # async: false — FakeAdapter reports to a pid held in application env, and
  # the adapter registry/supervisor carry their production names.
  use ExUnit.Case, async: false

  alias UniversalProxy.Cec
  alias UniversalProxy.Cec.{FakeAdapter, Server}

  @pubsub UniversalProxy.PubSub
  @dev "/dev/cec0"
  @output_key {"vc4-hdmi", nil, nil}
  @registry UniversalProxy.Cec.AdapterRegistry
  @adapter_sup UniversalProxy.Cec.AdapterSupervisor
  @claim [claim: [type: :playback, osd_name: "UniversalProxy"]]

  setup do
    Application.put_env(:universal_proxy, :cec_fake_pid, self())

    on_exit(fn ->
      for key <- [:cec_fake_pid, :cec_fake_replies, :cec_fake_start_error],
          do: Application.delete_env(:universal_proxy, key)
    end)

    start_supervised!({Registry, keys: :unique, name: @registry})
    start_supervised!({DynamicSupervisor, name: @adapter_sup, strategy: :one_for_one})

    {:ok, agent} =
      Agent.start_link(fn ->
        %{@dev => %{dev: @dev, index: 0, hdmi_device: "fef00700.hdmi", card_index: 1}}
      end)

    {:ok, task_sup} = Task.Supervisor.start_link()

    server =
      start_supervised!(
        {Server,
         name: nil,
         cec_module: FakeAdapter,
         enumerate: fn -> Agent.get(agent, & &1) end,
         output_lookup: fn
           @output_key -> {:ok, %{card_index: 1}}
           _ -> :error
         end,
         scan_interval_ms: 60_000,
         task_supervisor: task_sup}
      )

    {:ok, server: server, agent: agent}
  end

  defp adapter_pid do
    [{pid, _}] = Registry.lookup(@registry, @dev)
    pid
  end

  defp event(server, event), do: send(server, {:bodge_cec, adapter_pid(), event})

  test "opens an adapter per device, claiming playback, and reads its addresses", %{
    server: server
  } do
    assert_receive {:cec_adapter, @dev, {:start, @claim}}

    assert [%{dev: @dev, card_index: 1, phys_addr: "1.0.0.0", logical_address: 4, claimed?: true}] =
             Server.list_adapters(server)

    assert [{_pid, _}] = Registry.lookup(@registry, @dev)
    assert [_] = DynamicSupervisor.which_children(@adapter_sup)

    assert {:ok, %{dev: @dev}} = Server.adapter_for_card(server, 1)
    assert :error = Server.adapter_for_card(server, 0)
  end

  test "a Sendspin stream_start on the paired output fires One Touch Play", %{server: server} do
    assert_receive {:cec_adapter, @dev, {:start, _}}

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @output_key, %{event: "stream_start"}}
    )

    assert_receive {:cec_adapter, @dev, {:image_view_on, []}}
    assert_receive {:cec_adapter, @dev, {:active_source, []}}

    # Unrelated outputs (a USB DAC) don't touch CEC.
    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, {"1-1.3", 1, 2}, %{event: "stream_start"}}
    )

    refute_receive {:cec_adapter, @dev, {:image_view_on, []}}, 100
    assert Process.alive?(server)
  end

  test "adapter events update what is known about the link and the receiver, and are rebroadcast",
       %{server: server} do
    assert_receive {:cec_adapter, @dev, {:start, _}}
    Phoenix.PubSub.subscribe(@pubsub, Server.topic())

    event(server, {:message, 5, 4, {:report_audio_status, false, 33}})
    event(server, {:message, 0, 15, :standby})
    event(server, {:state_change, %{phys_addr: 0xFFFF, log_addrs: []}})

    assert {:ok,
            %{
              phys_addr: "f.f.f.f",
              logical_address: nil,
              claimed?: false,
              receiver: %{power: :standby, volume: 33, muted: false, updated_at: %DateTime{}}
            }} = Server.get_adapter(server, @dev)

    assert_receive {:cec_event, @dev, {:message, 5, 4, {:report_audio_status, false, 33}}}
    assert_receive {:cec_event, @dev, {:state_change, %{phys_addr: 0xFFFF}}}
  end

  test "status reports from devices other than the receiver are ignored", %{server: server} do
    assert_receive {:cec_adapter, @dev, {:start, _}}

    event(server, {:message, 5, 4, {:report_power_status, :on}})
    # The TV (0) answering its own power query, and a directed Standby from it.
    event(server, {:message, 0, 4, {:report_power_status, :standby}})
    event(server, {:message, 0, 4, {:report_audio_status, true, 80}})
    event(server, {:message, 0, 4, :standby})

    assert {:ok, %{receiver: %{power: :on, volume: nil, muted: nil}}} =
             Server.get_adapter(server, @dev)

    event(server, {:message, 5, 4, :standby})
    assert {:ok, %{receiver: %{power: :standby}}} = Server.get_adapter(server, @dev)
  end

  test "an unplugged adapter is dropped on the next scan and its process stopped", %{
    server: server,
    agent: agent
  } do
    assert_receive {:cec_adapter, @dev, {:start, _}}
    pid = adapter_pid()

    unplugged = Agent.get(agent, & &1)
    Agent.update(agent, fn _ -> %{} end)
    :ok = Server.rescan(server)

    assert Server.list_adapters(server) == []
    assert DynamicSupervisor.which_children(@adapter_sup) == []
    refute Process.alive?(pid)

    Agent.update(agent, fn _ -> unplugged end)
    :ok = Server.rescan(server)

    assert [{:undefined, new_pid, :worker, _}] = DynamicSupervisor.which_children(@adapter_sup)
    assert [{^new_pid, _}] = Registry.lookup(@registry, @dev)
    assert [%{dev: @dev, claimed?: true}] = Server.list_adapters(server)
  end

  @tag :capture_log
  test "a restarted adapter process is still the one stopped on unplug", %{
    server: server,
    agent: agent
  } do
    assert_receive {:cec_adapter, @dev, {:start, _}}
    original = adapter_pid()
    ref = Process.monitor(original)
    Process.exit(original, :kill)
    assert_receive {:DOWN, ^ref, :process, ^original, :killed}

    replacement = wait_for_adapter(original)
    assert replacement != original

    Agent.update(agent, fn _ -> %{} end)
    :ok = Server.rescan(server)

    assert DynamicSupervisor.which_children(@adapter_sup) == []
    refute Process.alive?(replacement)
  end

  @tag :capture_log
  test "an adapter that cannot be opened is listed unclaimed and retried on the next scan", %{
    agent: agent
  } do
    Application.put_env(:universal_proxy, :cec_fake_start_error, :enotsup)

    {:ok, task_sup} = Task.Supervisor.start_link()

    server =
      start_supervised!(
        {Server,
         name: nil,
         cec_module: FakeAdapter,
         enumerate: fn -> Agent.get(agent, & &1) end,
         output_lookup: fn _ -> :error end,
         scan_interval_ms: 60_000,
         task_supervisor: task_sup},
        id: :failing_server
      )

    # The outer setup's server already opened the adapter; make this one
    # start from nothing.
    for {pid, _} <- Registry.lookup(@registry, @dev),
        do: DynamicSupervisor.terminate_child(@adapter_sup, pid)

    :ok = Server.rescan(server)
    assert [%{dev: @dev, claimed?: false, phys_addr: nil}] = Server.list_adapters(server)
    assert DynamicSupervisor.which_children(@adapter_sup) == []

    Application.delete_env(:universal_proxy, :cec_fake_start_error)
    :ok = Server.rescan(server)
    assert [%{dev: @dev, claimed?: true, phys_addr: "1.0.0.0"}] = Server.list_adapters(server)
  end

  defp wait_for_adapter(old, attempts \\ 50) do
    case Registry.lookup(@registry, @dev) do
      [{pid, _}] when pid != old ->
        pid

      _ when attempts > 0 ->
        Process.sleep(10)
        wait_for_adapter(old, attempts - 1)

      other ->
        flunk("adapter for #{@dev} not restarted: #{inspect(other)}")
    end
  end

  describe "facade commands against an explicit adapter" do
    setup %{server: server} do
      assert_receive {:cec_adapter, @dev, {:start, _}}
      {:ok, adapter} = Server.get_adapter(server, @dev)
      {:ok, adapter: adapter}
    end

    test "one_touch_play skips Active Source without a valid physical address", %{
      adapter: adapter
    } do
      assert :ok = Cec.one_touch_play(%{adapter | phys_addr: "f.f.f.f"}, cec: FakeAdapter)
      assert_receive {:cec_adapter, @dev, {:image_view_on, []}}
      refute_receive {:cec_adapter, @dev, {:active_source, []}}, 50
    end

    test "a refused Active Source is reported as such", %{adapter: adapter} do
      Application.put_env(:universal_proxy, :cec_fake_replies, %{
        active_source: {:error, :not_configured}
      })

      assert {:error, {:active_source, :not_configured}} =
               Cec.one_touch_play(adapter, cec: FakeAdapter)
    end

    test "user controls go to the receiver address in BodgeCEC's key names", %{
      adapter: adapter
    } do
      assert :ok = Cec.user_control(adapter, :volume_up, cec: FakeAdapter, receiver_la: 5)
      assert_receive {:cec_adapter, @dev, {:user_control, [5, :volume_up]}}

      assert :ok = Cec.user_control(adapter, :power_on, cec: FakeAdapter, receiver_la: 5)
      assert_receive {:cec_adapter, @dev, {:user_control, [5, :power_on_function]}}

      assert :ok = Cec.user_control(adapter, 0x44, cec: FakeAdapter, receiver_la: 0)
      assert_receive {:cec_adapter, @dev, {:user_control, [0, 0x44]}}
    end
  end

  describe "commands via the registered server" do
    setup %{agent: agent} do
      named =
        start_supervised!(
          {Server,
           cec_module: FakeAdapter,
           enumerate: fn -> Agent.get(agent, & &1) end,
           output_lookup: fn _ -> :error end,
           scan_interval_ms: 60_000},
          id: :named_server
        )

      :ok = Server.rescan(named)
      {:ok, named: named}
    end

    test "a delivered Standby marks the receiver as going to standby", %{named: named} do
      assert :ok = Cec.standby(@dev, cec: FakeAdapter)
      assert_receive {:cec_adapter, @dev, {:standby, [5]}}
      assert {:ok, %{receiver: %{power: :to_standby}}} = Server.get_adapter(named, @dev)
    end

    test "a NACKed Standby is an error and leaves the receiver cache alone", %{named: named} do
      Application.put_env(:universal_proxy, :cec_fake_replies, %{standby: {:error, :nack}})

      assert {:error, :nack} = Cec.standby(@dev, cec: FakeAdapter)

      assert {:ok, %{receiver: %{power: :unknown, updated_at: nil}}} =
               Server.get_adapter(named, @dev)
    end

    test "status requests decode the reply and record it", %{named: named} do
      assert {:ok, :standby} = Cec.power_status(@dev, cec: FakeAdapter)
      assert_receive {:cec_adapter, @dev, {:give_device_power_status, [5]}}

      assert {:ok, %{volume: 40, muted: false}} = Cec.audio_status(@dev, cec: FakeAdapter)
      assert_receive {:cec_adapter, @dev, {:give_audio_status, [5]}}

      assert {:ok, %{receiver: %{power: :standby, volume: 40, muted: false}}} =
               Server.get_adapter(named, @dev)

      # A receiver that won't say its volume, and a power byte we don't know.
      Application.put_env(:universal_proxy, :cec_fake_replies, %{
        give_audio_status: {:ok, %{muted: true, volume: :unknown}},
        give_device_power_status: {:ok, 0x42}
      })

      assert {:ok, %{volume: nil, muted: true}} = Cec.audio_status(@dev, cec: FakeAdapter)
      assert {:ok, :unknown} = Cec.power_status(@dev, cec: FakeAdapter)
    end

    test "a command to an adapter whose process is gone is an error, not an exit", %{
      named: named
    } do
      {:ok, adapter} = Server.get_adapter(named, @dev)
      DynamicSupervisor.terminate_child(@adapter_sup, adapter_pid())
      assert {:error, :adapter_down} = Cec.standby(adapter, cec: FakeAdapter)
    end
  end

  test "facade degrades when the server is not running" do
    assert Cec.list_adapters() == []
    assert Cec.get_adapter(@dev) == :error
    assert {:error, :cec_unavailable} = Cec.power_status(@dev, cec: FakeAdapter)
  end
end
