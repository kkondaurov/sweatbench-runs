defmodule GroupStay.ServerProcess do
  @moduledoc """
  Runs the normal Phoenix command in an independent VM for HTTP durability tests.
  The test supervisor owns its lifetime, including cleanup after a failed test.
  """
  use GenServer

  def start_link(options), do: GenServer.start_link(__MODULE__, options)
  def output(server), do: GenServer.call(server, :output)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["--erl", "+S 2:2 +SDio 2", "-S", "mix", "phx.server", "--no-compile"],
        cd: Path.expand("../..", __DIR__),
        env: [
          {~c"MIX_ENV", ~c"test"},
          {~c"PORT", to_charlist(Integer.to_string(options[:port]))},
          {~c"GROUP_STAY_DATABASE_PATH", to_charlist(options[:database])}
        ]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {:ok, %{port: port, os_pid: os_pid, output: ""}}
  end

  @impl true
  def handle_call(:output, _from, state), do: {:reply, state.output, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {:noreply, %{state | output: String.slice(state.output <> data, -20_000, 20_000)}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:noreply, %{state | os_pid: nil, output: state.output <> "\nExit status: #{status}"}}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{os_pid: nil}), do: :ok

  def terminate(_reason, %{os_pid: os_pid, port: port}) do
    System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      2000 -> System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    if Port.info(port), do: Port.close(port)
    :ok
  end
end
