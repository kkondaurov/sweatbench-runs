defmodule GroupStay.Reservations.AllocationOrder do
  @moduledoc """
  Maintains one chronological order across cash and hotel-credit allocations.

  Cash and credit have different provenance and therefore live in separate
  tables. Transfers and provider corrections nevertheless need to treat them
  as one funding stream. The shared integer order makes that chronology
  explicit and deterministic.
  """

  import Ecto.Query

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CashAllocation,
    CashFunding,
    CreditAllocation,
    PartnerOperation,
    Room
  }

  @doc "Returns the next allocation order inside the serialized operation transaction."
  def next do
    cash_order = Repo.aggregate(CashAllocation, :max, :allocation_order) || 0
    credit_order = Repo.aggregate(CreditAllocation, :max, :allocation_order) || 0
    max(cash_order, credit_order) + 1
  end

  @doc false
  def prepare_upgrade(repo) do
    add_column_unless_present(
      repo,
      "cash_allocations",
      "allocation_order",
      "INTEGER NOT NULL DEFAULT 0"
    )

    add_column_unless_present(
      repo,
      "credit_allocations",
      "allocation_order",
      "INTEGER NOT NULL DEFAULT 0"
    )

    add_column_unless_present(
      repo,
      "cash_fundings",
      "participated_in_transfer",
      "BOOLEAN NOT NULL DEFAULT 0"
    )
  end

  @doc false
  def backfill do
    operation_orders =
      Repo.all(
        from operation in PartnerOperation,
          select: {operation.operation_id, operation.commit_order}
      )
      |> Map.new()

    cash =
      Repo.all(
        from allocation in CashAllocation,
          join: funding in CashFunding,
          on: funding.id == allocation.cash_funding_id,
          join: room in Room,
          on: room.id == allocation.room_id,
          select: {allocation, funding.funding_order, room.position}
      )
      |> Enum.map(fn {allocation, funding_order, room_position} ->
        event_order = if funding_order == 0, do: {0, 0}, else: {2, funding_order}
        {event_order, room_position, allocation.id, allocation}
      end)

    credit =
      Repo.all(
        from allocation in CreditAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          select: {allocation, room.position}
      )
      |> Enum.map(fn {allocation, room_position} ->
        event_order =
          case allocation.funding_operation_id do
            nil -> {1, 0}
            operation_id -> {2, Map.fetch!(operation_orders, operation_id)}
          end

        {event_order, room_position, allocation.id, allocation}
      end)

    cash
    |> Kernel.++(credit)
    |> Enum.sort_by(fn {event_order, room_position, allocation_id, _allocation} ->
      {event_order, room_position, allocation_id}
    end)
    |> Enum.with_index(1)
    |> Enum.each(fn {{_event_order, _room_position, _allocation_id, allocation}, order} ->
      allocation
      |> Ecto.Changeset.change(allocation_order: order)
      |> Repo.update!()
    end)
  end

  defp add_column_unless_present(repo, table, column, definition) do
    columns =
      repo.query!("PRAGMA table_info('#{table}')").rows
      |> Enum.map(fn [_position, name | _rest] -> name end)

    unless column in columns do
      repo.query!("ALTER TABLE #{table} ADD COLUMN #{column} #{definition}")
    end
  end
end
