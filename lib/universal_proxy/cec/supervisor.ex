defmodule UniversalProxy.Cec.Supervisor do
  @moduledoc """
  HDMI-CEC subtree: a `Registry` naming the per-adapter `BodgeCEC` processes
  by device path, the `DynamicSupervisor` running them, and the
  `UniversalProxy.Cec.Server` inventory.

  `:one_for_all` so a Server restart also restarts the adapter processes and
  their registry, re-creating them from a clean slate (it re-discovers
  adapters on init) instead of leaving orphans the new Server doesn't know
  about. Returns `:ignore` unless the `UniversalProxy.Cec` env has
  `enabled: true` (set for targets, off on host/test), so a dev machine
  never opens `/dev/cecN`.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start() | :ignore
  def start_link(opts \\ []) do
    if enabled?() do
      Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :ignore
    end
  end

  @spec enabled?() :: boolean()
  def enabled? do
    :universal_proxy
    |> Application.get_env(UniversalProxy.Cec, [])
    |> Keyword.get(:enabled, false)
  end

  @impl true
  def init(opts) do
    children = [
      {Registry, keys: :unique, name: UniversalProxy.Cec.AdapterRegistry},
      {DynamicSupervisor, name: UniversalProxy.Cec.AdapterSupervisor, strategy: :one_for_one},
      {UniversalProxy.Cec.Server, opts}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
