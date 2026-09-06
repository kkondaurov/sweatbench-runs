defmodule GroupStay.Payments do
  @moduledoc """
  Provider corrections against one durably recorded cash payment:
  reductions of held cash, whole-payment chargebacks, and per-payment
  reconciliation.

  A payment's recorded cash partitions into held, refunded, retained,
  converted, reduced, and charged-back dispositions that always sum to the
  recorded amount and agree with the group, room, and ledger views. Only
  cash still held on active rooms moves through these operations; refunded,
  retained, or converted cash is settled history. Legacy funding has no
  durable operation identity and cannot be addressed at all.

  The stored result of a corrected payment is never rewritten: retrying the
  original payment keeps returning its exact original result.
  """

  import Ecto.Query

  alias GroupStay.Credit
  alias GroupStay.Fundings
  alias GroupStay.Groups
  alias GroupStay.Groups.Group
  alias GroupStay.Ledger
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  @payment_type "record_cash_payment"

  @type correction_error :: {:error, atom(), map()}

  @doc """
  Records a provider reduction against one payment's still-held cash,
  removing its allocations in reverse fill order and reopening the group's
  outstanding deposit by the amount removed.
  """
  def reduce_cash_payment(payment_operation_id, amount_cents, expected_revision \\ nil) do
    with {:ok, group} <- load_payment_group(payment_operation_id, :payment_not_reducible),
         :ok <- check_revision(group, expected_revision),
         :ok <- ensure_reducible(payment_operation_id),
         :ok <- validate_amount(amount_cents) do
      held = Fundings.payment_held_cents(payment_operation_id)

      if amount_cents <= held do
        :ok = Fundings.remove_payment_cash(payment_operation_id, amount_cents)
        {:ok, _} = Ledger.record_reduction(group.id, payment_operation_id, amount_cents)

        {:ok,
         %{
           payment_operation_id: payment_operation_id,
           group_id: group.group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: Groups.outstanding_cents(group),
           revision: bump(group)
         }}
      else
        {:error, :reduction_exceeds_held_cash, %{group_id: group.group_id}}
      end
    end
  end

  @doc """
  Reverses all cash from one durably recorded payment except any portion
  already recorded as reduced: held allocations are removed in reverse fill
  order, settled portions are reclassified to charged-back cash, and
  converted principal's credit entitlement is revoked.
  """
  def charge_back_payment(payment_operation_id, expected_revision \\ nil) do
    with {:ok, group} <- load_payment_group(payment_operation_id, :payment_not_chargeable),
         :ok <- check_revision(group, expected_revision),
         {:ok, move_cents} <- ensure_chargeable(payment_operation_id) do
      # The reversed cash is everything except what was already recorded as
      # reduced: the still-held allocations plus every settled portion.
      held = Fundings.payment_held_cents(payment_operation_id)

      if held > 0 do
        :ok = Fundings.remove_payment_cash(payment_operation_id, held)
      end

      :ok = Ledger.reclassify_settled_to_chargeback(payment_operation_id)
      :ok = Credit.claw_back_entitlements(payment_operation_id)

      # The new chargeback entry carries the held portion; the reclassified
      # settlement entries already carry the rest of the reversal exactly.
      if held > 0 do
        {:ok, _} = Ledger.record_chargeback(group.id, payment_operation_id, held)
      end

      {:ok,
       %{
         payment_operation_id: payment_operation_id,
         group_id: group.group_id,
         charged_back_cents: move_cents,
         outstanding_deposit_cents: Groups.outstanding_cents(group),
         revision: bump(group)
       }}
    end
  end

  @doc """
  Reads the current disposition of one recorded payment's cash. Reading a
  statement never changes state.
  """
  def statement(payment_operation_id) do
    case Record.fetch(payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      record ->
        if applied_cash_payment?(record) do
          {:ok, build_statement(payment_operation_id)}
        else
          {:error, :payment_not_reconcilable}
        end
    end
  end

  @doc """
  Whether the stored record is a durably applied cash payment.
  """
  def applied_cash_payment?(%Record{} = record) do
    record.type == @payment_type and result_status(record) == "applied"
  end

  defp build_statement(operation_id) do
    %{
      payment_operation_id: operation_id,
      original_group_id: original_group_id(operation_id),
      recorded_cents: entry_sum(operation_id, "payment"),
      held_cents: Fundings.payment_held_cents(operation_id),
      refunded_cents: entry_sum(operation_id, "refund"),
      retained_cents: entry_sum(operation_id, "retention"),
      converted_to_credit_cents: entry_sum(operation_id, "credit_conversion"),
      reduced_cents: entry_sum(operation_id, "reduction"),
      charged_back_cents: entry_sum(operation_id, "chargeback")
    }
  end

  # Resolves the addressed group from the stored result of an applied cash
  # payment; anything else is no correction target at all and fails with the
  # caller's domain code before any revision is consulted.
  defp load_payment_group(payment_operation_id, domain_error) do
    case Record.fetch(payment_operation_id) do
      nil ->
        {:error, :operation_not_found, %{}}

      record ->
        if applied_cash_payment?(record) do
          group_id = stored_result(record)["group_id"]

          case Repo.get_by(Group, group_id: group_id) do
            nil -> {:error, domain_error, %{}}
            group -> {:ok, group}
          end
        else
          {:error, domain_error, %{}}
        end
    end
  end

  defp ensure_reducible(payment_operation_id) do
    if Fundings.payment_held_cents(payment_operation_id) > 0 do
      :ok
    else
      {:error, :payment_not_reducible, %{}}
    end
  end

  # Returns the total cash this operation will move to charged-back
  # classification: everything except what was already recorded as reduced.
  defp ensure_chargeable(payment_operation_id) do
    recorded = entry_sum(payment_operation_id, "payment")
    already_charged_back = entry_sum(payment_operation_id, "chargeback")
    reduced = entry_sum(payment_operation_id, "reduction")

    cond do
      already_charged_back > 0 ->
        {:error, :payment_not_chargeable, %{}}

      recorded - reduced <= 0 ->
        {:error, :payment_not_chargeable, %{}}

      true ->
        {:ok, recorded - reduced}
    end
  end

  defp check_revision(_group, nil), do: :ok

  defp check_revision(group, expected_revision) do
    if expected_revision == group.revision,
      do: :ok,
      else:
        {:error, :stale_revision,
         %{
           group_id: group.group_id,
           expected_revision: expected_revision,
           actual_revision: group.revision
         }}
  end

  defp validate_amount(amount) do
    if is_integer(amount) and amount > 0 do
      :ok
    else
      {:error, :invalid_amount, %{}}
    end
  end

  defp bump(group), do: Groups.bump_revision!(group)

  defp entry_sum(operation_id, kind) do
    from(e in Ledger.Entry,
      where: e.operation_id == ^operation_id and e.kind == ^kind,
      select: coalesce(sum(e.amount_cents), 0)
    )
    |> Repo.one()
  end

  defp original_group_id(operation_id) do
    from(e in Ledger.Entry,
      join: g in Group,
      on: g.id == e.group_id,
      where: e.operation_id == ^operation_id and e.kind == "payment",
      select: g.group_id
    )
    |> Repo.one()
  end

  defp stored_result(record), do: Jason.decode!(record.result_json)

  defp result_status(record), do: stored_result(record)["status"]
end
