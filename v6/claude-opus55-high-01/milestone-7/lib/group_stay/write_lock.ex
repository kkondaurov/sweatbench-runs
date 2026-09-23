defmodule GroupStay.WriteLock do
  @moduledoc """
  Admits one write transaction at a time in this node.

  SQLite allows a single writer, and a connection waiting for the write lock busy-waits while
  holding its driver mutex. Exqlite finalizes a prepared statement under the mutex of the
  connection that prepared it, and Ecto's query cache passes statements between connections. A
  writer that finalizes a statement owned by a waiting connection therefore stalls until that
  waiter's busy timeout fails it. Queueing writers here, before they reach SQLite, means no local
  connection waits inside SQLite while another holds the write lock.

  A holder that exits releases the lock.
  """
  use GenServer

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @doc "Runs `fun` while holding the lock."
  def run(fun) when is_function(fun, 0) do
    :ok = GenServer.call(__MODULE__, :acquire, :infinity)

    try do
      fun.()
    after
      :ok = GenServer.call(__MODULE__, :release, :infinity)
    end
  end

  @impl true
  def init(:ok), do: {:ok, %{holder: nil, waiting: :queue.new()}}

  @impl true
  def handle_call(:acquire, {pid, _tag} = from, %{holder: nil} = state) do
    GenServer.reply(from, :ok)
    {:noreply, %{state | holder: {pid, Process.monitor(pid)}}}
  end

  def handle_call(:acquire, from, state),
    do: {:noreply, %{state | waiting: :queue.in(from, state.waiting)}}

  def handle_call(:release, {pid, _tag}, %{holder: {pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:reply, :ok, grant_next(state)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{holder: {_holder, ref}} = state),
    do: {:noreply, grant_next(state)}

  # Monitors of earlier holders are flushed on release, so nothing else is expected here.
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  defp grant_next(state) do
    case :queue.out(state.waiting) do
      {{:value, {pid, _tag} = from}, waiting} ->
        if Process.alive?(pid) do
          GenServer.reply(from, :ok)
          %{state | holder: {pid, Process.monitor(pid)}, waiting: waiting}
        else
          grant_next(%{state | waiting: waiting})
        end

      {:empty, waiting} ->
        %{state | holder: nil, waiting: waiting}
    end
  end
end
