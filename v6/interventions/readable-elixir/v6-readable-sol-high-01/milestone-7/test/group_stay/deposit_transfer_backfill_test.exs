defmodule GroupStay.DepositTransferBackfillTest do
  use GroupStay.DataCase

  alias GroupStay.Credits.CreditAllocation
  alias GroupStay.DepositTransferBackfill
  alias GroupStay.PartnerOperations
  alias GroupStay.Payments.{CashAllocation, CashPayment, CashPaymentGroupDisposition}

  test "reconstructs allocation order and per-group settlement history" do
    PartnerOperations.process_batch([
      open_group("donor", "guest", 5_000),
      cash_payment("donor-cash", "donor", 1_000),
      cancel_to_credit("credit-origin", "donor"),
      open_group("target", "guest", 5_000),
      cash_payment("target-cash", "target", 500),
      credit_payment("target-credit", "target", 500)
    ])

    Repo.update_all(CashAllocation, set: [allocation_order: 0])
    Repo.update_all(CreditAllocation, set: [allocation_order: 0])
    Repo.delete_all(CashPaymentGroupDisposition)

    DepositTransferBackfill.run(Repo)

    cash_order = Repo.one!(from allocation in CashAllocation, select: allocation.allocation_order)

    credit_order =
      Repo.one!(from allocation in CreditAllocation, select: allocation.allocation_order)

    assert cash_order > 0
    assert credit_order > cash_order

    donor_payment = Repo.get_by!(CashPayment, payment_operation_id: "donor-cash")

    disposition =
      Repo.get_by!(CashPaymentGroupDisposition, cash_payment_id: donor_payment.id)

    assert disposition.refunded_cents == 0
    assert disposition.retained_cents == 0
    assert disposition.converted_to_credit_cents == 1_000
  end

  defp open_group(group_id, guest_id, nightly_rate) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-01",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "hotel",
      "arrival_on" => "2027-03-01",
      "departure_on" => "2027-03-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => nightly_rate}]
    }
  end

  defp cash_payment(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-02",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp credit_payment(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-11-02",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancel_to_credit(operation_id, group_id) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => "2026-11-01",
      "group_id" => group_id,
      "refund_method" => "hotel_credit"
    }
  end
end
