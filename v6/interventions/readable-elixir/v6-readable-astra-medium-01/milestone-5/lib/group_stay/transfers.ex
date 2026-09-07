defmodule GroupStay.Transfers do
  @moduledoc """
  Moves held deposits between a guest's active reservations. Both revision guards
  are checked before domain rules; all validation precedes allocation mutations.
  The caller owns the transaction and durable operation result.
  """
  alias GroupStay.{Accounting, Reservations}
  alias GroupStay.Reservations.Group

  def apply(op) do
    with :ok <- required_fields(op),
         {:ok, source} <- find_group(op["source_group_id"]),
         {:ok, destination} <- find_group(op["destination_group_id"]),
         :ok <- revision(source, op, "expected_revision"),
         :ok <- revision(destination, op, "destination_expected_revision"),
         :ok <- validate(source, destination, op["amount_cents"]) do
      {source, destination} = Accounting.transfer(source, destination, op["amount_cents"])

      %{
        status: "applied",
        source_group_id: source.group_id,
        destination_group_id: destination.group_id,
        amount_cents: op["amount_cents"],
        source_outstanding_deposit_cents: Group.outstanding(source),
        destination_outstanding_deposit_cents: Group.outstanding(destination),
        source_revision: source.revision,
        destination_revision: destination.revision
      }
    else
      {:error, result} -> result
    end
  end

  defp required_fields(op) do
    if is_binary(op["destination_group_id"]) and op["destination_group_id"] != "" and
         Map.has_key?(op, "amount_cents"),
       do: :ok,
       else: reject("invalid_operation")
  end

  defp find_group(id) do
    case Reservations.get_group(id) do
      nil -> reject("group_not_found", %{group_id: id})
      group -> {:ok, group}
    end
  end

  defp revision(group, op, key) do
    if Map.has_key?(op, key) and op[key] !== group.revision do
      reject("stale_revision", %{
        group_id: group.group_id,
        expected_revision: op[key],
        actual_revision: group.revision
      })
    else
      :ok
    end
  end

  defp validate(source, destination, amount) do
    cond do
      source.group_id == destination.group_id or source.guest_id != destination.guest_id ->
        reject("invalid_transfer")

      source.status != "active" ->
        reject("group_not_active", %{group_id: source.group_id})

      destination.status != "active" ->
        reject("group_not_active", %{group_id: destination.group_id})

      not is_integer(amount) or amount <= 0 ->
        reject("invalid_amount")

      amount > source.deposit_paid_cents ->
        reject("transfer_exceeds_held_funding")

      amount > Group.outstanding(destination) ->
        reject("transfer_exceeds_outstanding")

      true ->
        :ok
    end
  end

  defp reject(code, fields \\ %{}),
    do: {:error, Map.merge(%{status: "rejected", code: code}, fields)}
end
