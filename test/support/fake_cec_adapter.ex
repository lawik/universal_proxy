defmodule UniversalProxy.Cec.FakeAdapter do
  @moduledoc """
  Stand-in for `BodgeCEC` in the Cec tests: a GenServer offering the subset
  of BodgeCEC's API the subsystem uses, started and registered the way the
  Server starts the real thing.

  Every call is reported to the pid registered under `:cec_fake_pid` in the
  application env as `{:cec_adapter, dev, {function, args}}` (the Cec tests
  are `async: false`), and answered from a canned table that a test can
  override per function through `:cec_fake_replies`
  (`%{standby: {:error, :nack}}`). `:cec_fake_start_error` makes
  `start_link/1` fail the way an unopenable node would. Like BodgeCEC, the
  process sends its initial `{:state_change, _}` to the `:notify` pids.
  """

  use GenServer

  @phys_addr 0x1000
  @log_addrs [4]

  @canned %{
    image_view_on: :ok,
    active_source: :ok,
    standby: :ok,
    user_control: :ok,
    give_device_power_status: {:ok, :standby},
    give_audio_status: {:ok, %{muted: false, volume: 40}}
  }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def info(adapter), do: GenServer.call(adapter, :info)
  def subscribe(adapter), do: GenServer.call(adapter, {:subscribe, self()})
  def image_view_on(adapter), do: command(adapter, :image_view_on, [])
  def active_source(adapter), do: command(adapter, :active_source, [])
  def standby(adapter, dest), do: command(adapter, :standby, [dest])
  def user_control(adapter, dest, key), do: command(adapter, :user_control, [dest, key])

  def give_device_power_status(adapter, dest, _opts \\ []),
    do: command(adapter, :give_device_power_status, [dest])

  def give_audio_status(adapter, dest, _opts \\ []),
    do: command(adapter, :give_audio_status, [dest])

  defp command(adapter, fun, args), do: GenServer.call(adapter, {:command, fun, args})

  @impl true
  def init(opts) do
    dev = Keyword.fetch!(opts, :device)

    case Application.get_env(:universal_proxy, :cec_fake_start_error) do
      nil ->
        report(dev, {:start, Keyword.take(opts, [:claim])})
        subscribers = opts |> Keyword.get(:notify, []) |> List.wrap()
        state = %{dev: dev, subscribers: subscribers}
        notify(state, {:state_change, %{phys_addr: @phys_addr, log_addrs: @log_addrs}})
        {:ok, state}

      reason ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply, %{device: state.dev, phys_addr: @phys_addr, log_addrs: @log_addrs}, state}
  end

  def handle_call({:subscribe, pid}, _from, state),
    do: {:reply, :ok, %{state | subscribers: Enum.uniq([pid | state.subscribers])}}

  def handle_call({:command, fun, args}, _from, state) do
    report(state.dev, {fun, args})
    overrides = Application.get_env(:universal_proxy, :cec_fake_replies, %{})
    {:reply, Map.get(overrides, fun, Map.fetch!(@canned, fun)), state}
  end

  defp report(dev, call) do
    if pid = Application.get_env(:universal_proxy, :cec_fake_pid),
      do: send(pid, {:cec_adapter, dev, call})
  end

  defp notify(state, event) do
    Enum.each(state.subscribers, &send(&1, {:bodge_cec, self(), event}))
  end
end
