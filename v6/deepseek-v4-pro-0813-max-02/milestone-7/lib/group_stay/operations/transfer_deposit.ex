defmodule GroupStay.Operations.TransferDeposit do
  @moduledoc """
  Moves part of the applied deposit between two active groups of the same
  guest from a `transfer_deposit` operation.

  The source and destination groups must both exist, be active, be distinct,
  and belong to the same guest. Held funding is drained from the source's
  active-room allocations in reverse allocation order regardless of funding
  kind, and then fills the destination's active rooms in their original
  order. Each moved slice keeps its provenance: cash keeps its payment
  operation identity and hotel credit keeps its original lot.

  A transfer settles nothing: no credit bonus is computed, applied credit
  keeps its paused expiry, and no ledger total changes. Group existence is
  resolved for the source first and then the destination. After both exist,
  the source's `expected_revision` and then the destination's
  `destination_expected_revision` are checked before the transfer rules.
  Both groups' revisions increment exactly once.
  """

  alias GroupStay.Groups.Group
  alias GroupStay.FinanceReporting
  alias GroupStay.Operations
  alias GroupStay.Repo
  alias GroupStay.RoomAccounting

  @required_fields [
    :operation_id,
    :source_group_id,
    :destination_group_id,
    :amount_cents
  ]

  @spec apply(map()) :: map()
  def apply(operation) do
    with {:ok, fields} <- Operations.require_fields(operation, @required_fields),
         true <- is_binary(fields.source_group_id),
         true <- is_binary(fields.destination_group_id) do
      transfer(operation, fields)
    else
      _ -> Operations.rejected(operation, "invalid_operation")
    end
  end

  defp transfer(operation, fields) do
    case Repo.transaction(fn ->
           source = Repo.get_by(Group, group_id: fields.source_group_id)
           destination = Repo.get_by(Group, group_id: fields.destination_group_id)
           apply_transfer(operation, fields, source, destination)
         end) do
      {:ok, result} -> result
      _ -> Operations.rejected(operation, "invalid_operation")
    end
  end

  defp apply_transfer(operation, _fields, nil, _destination) do
    Operations.rejected(operation, "group_not_found", group_id: operation["source_group_id"])
  end

  defp apply_transfer(operation, _fields, _source, nil) do
    Operations.rejected(operation, "group_not_found", group_id: operation["destination_group_id"])
  end

  defp apply_transfer(operation, fields, source, destination) do
    with :ok <- check_revision(operation, source, "expected_revision"),
         :ok <- check_revision(operation, destination, "destination_expected_revision"),
         :ok <- check_valid_pair(operation, source, destination),
         :ok <- check_active(operation, source),
         :ok <- check_active(operation, destination),
         :ok <- check_amount(operation, fields.amount_cents),
         :ok <- check_funding(operation, source, fields.amount_cents),
         :ok <- check_outstanding(operation, destination, fields.amount_cents) do
      move(operation, source, destination, fields.amount_cents)
    else
      {:rejected, result} -> result
    end
  end

  defp check_revision(operation, group, guard_field) do
    case Map.get(operation, guard_field) do
      nil ->
        :ok

      expected ->
        if expected == group.revision do
          :ok
        else
          {:rejected,
           Operations.rejected(operation, "stale_revision",
             group_id: group.group_id,
             expected_revision: expected,
             actual_revision: group.revision
           )}
        end
    end
  end

  defp check_valid_pair(operation, source, destination) do
    if source.id == destination.id or source.guest_id != destination.guest_id do
      {:rejected, Operations.rejected(operation, "invalid_transfer")}
    else
      :ok
    end
  end

  defp check_active(_operation, %Group{status: "active"}), do: :ok

  defp check_active(operation, group) do
    {:rejected, Operations.rejected(operation, "group_not_active", group_id: group.group_id)}
  end

  defp check_amount(operation, amount_cents) do
    if is_integer(amount_cents) and amount_cents > 0 do
      :ok
    else
      {:rejected, Operations.rejected(operation, "invalid_amount")}
    end
  end

  defp check_funding(operation, source, amount_cents) do
    if RoomAccounting.held_funding_cents(source.id) >= amount_cents do
      :ok
    else
      {:rejected, Operations.rejected(operation, "transfer_exceeds_held_funding")}
    end
  end

  defp check_outstanding(operation, destination, amount_cents) do
    outstanding = destination.deposit_due_cents - destination.deposit_paid_cents

    if amount_cents > outstanding do
      {:rejected, Operations.rejected(operation, "transfer_exceeds_outstanding")}
    else
      :ok
    end
  end

  defp move(operation, source, destination, amount_cents) do
    RoomAccounting.transfer_held_funding(source, destination, amount_cents)

    RoomAccounting.sync_group_columns(source.id)
    RoomAccounting.sync_group_columns(destination.id)

    FinanceReporting.record_cash(operation, [
      %{
        property_id: source.property_id,
        classification: "transferred_out",
        amount_cents: amount_cents
      },
      %{
        property_id: destination.property_id,
        classification: "transferred_in",
        amount_cents: amount_cents
      }
    ])

    source = RoomAccounting.bump_revision(source.id)
    destination = RoomAccounting.bump_revision(destination.id)

    Operations.applied(operation,
      source_group_id: source.group_id,
      destination_group_id: destination.group_id,
      amount_cents: amount_cents,
      source_outstanding_deposit_cents: source.deposit_due_cents - source.deposit_paid_cents,
      destination_outstanding_deposit_cents:
        destination.deposit_due_cents - destination.deposit_paid_cents,
      source_revision: source.revision,
      destination_revision: destination.revision
    )
  end
end
