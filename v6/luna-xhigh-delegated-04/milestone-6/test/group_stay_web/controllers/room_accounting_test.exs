defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.{CreditAllocation, CreditLot, Group, Repo}

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2027-01-02",
        "group_id" => "group-1",
        "guest_id" => "guest-1",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-04-01",
        "departure_on" => "2027-04-02",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "a", "nightly_rate_cents" => 20},
          %{"room_id" => "b", "nightly_rate_cents" => 30}
        ]
      },
      overrides
    )
  end

  defp post_batch(conn, operations),
    do: post(conn, "/api/v1/partner-batches", %{"operations" => operations})

  defp result(conn, operation),
    do: post_batch(conn, [operation]) |> json_response(200) |> Map.fetch!("results") |> hd()

  defp credit_lot(attrs) do
    Repo.insert!(
      struct(
        %CreditLot{
          guest_id: "guest-1",
          source_operation_id: "source-1",
          remaining_cents: 20,
          expires_on: ~D[2027-06-01],
          cash_converted_cents: 0,
          issued_on: ~D[2027-01-01]
        },
        attrs
      )
    )
  end

  test "allocates funding to rooms, reduces in reverse fill order, and reconciles cash", %{
    conn: conn
  } do
    assert result(conn, open_operation())["revision"] == 1

    assert result(conn, %{
             "operation_id" => "pay-1",
             "type" => "record_cash_payment",
             "occurred_on" => "2027-01-03",
             "group_id" => "group-1",
             "amount_cents" => 8
           })["outstanding_deposit_cents"] == 2

    assert result(conn, %{
             "operation_id" => "reduce-1",
             "type" => "reduce_cash_payment",
             "payment_operation_id" => "pay-1",
             "amount_cents" => 5,
             "expected_revision" => 2
           }) == %{
             "operation_id" => "reduce-1",
             "status" => "applied",
             "payment_operation_id" => "pay-1",
             "group_id" => "group-1",
             "amount_cents" => 5,
             "outstanding_deposit_cents" => 7,
             "revision" => 3
           }

    assert json_response(get(conn, "/api/v1/groups/group-1"), 200)["data"] ==
             %{
               "group_id" => "group-1",
               "guest_id" => "guest-1",
               "property_id" => "ams-canal",
               "booked_on" => "2027-01-02",
               "arrival_on" => "2027-04-01",
               "departure_on" => "2027-04-02",
               "rate_plan" => "flexible",
               "policy_version" => "flex-30",
               "refundable_until" => "2027-03-02",
               "status" => "active",
               "rooms" => [
                 %{
                   "room_id" => "a",
                   "nightly_rate_cents" => 20,
                   "status" => "active",
                   "lodging_amount_cents" => 20,
                   "deposit_due_cents" => 4,
                   "cash_paid_cents" => 3,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "b",
                   "nightly_rate_cents" => 30,
                   "status" => "active",
                   "lodging_amount_cents" => 30,
                   "deposit_due_cents" => 6,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 }
               ],
               "lodging_total_cents" => 50,
               "deposit_due_cents" => 10,
               "deposit_paid_cents" => 3,
               "cash_paid_cents" => 3,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 7,
               "revision" => 3
             }

    assert json_response(get(conn, "/api/v1/payments/pay-1"), 200)["data"] == %{
             "payment_operation_id" => "pay-1",
             "original_group_id" => "group-1",
             "recorded_cents" => 8,
             "held_cents" => 3,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 5,
             "charged_back_cents" => 0
           }
  end

  test "cancels selected rooms atomically and preserves room order", %{conn: conn} do
    result(conn, open_operation())

    result(conn, %{
      "operation_id" => "pay-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-03",
      "group_id" => "group-1",
      "amount_cents" => 10
    })

    assert result(conn, %{
             "operation_id" => "cancel-b",
             "type" => "cancel_rooms",
             "occurred_on" => "2027-01-03",
             "group_id" => "group-1",
             "room_ids" => ["b"],
             "expected_revision" => 2
           }) == %{
             "operation_id" => "cancel-b",
             "status" => "applied",
             "group_id" => "group-1",
             "cancelled_room_ids" => ["b"],
             "refunded_cents" => 6,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 3
           }

    group = json_response(get(conn, "/api/v1/groups/group-1"), 200)["data"]
    assert group["deposit_due_cents"] == 4
    assert group["deposit_paid_cents"] == 4
    assert group["outstanding_deposit_cents"] == 0

    assert Enum.map(group["rooms"], &{&1["room_id"], &1["status"]}) == [
             {"a", "active"},
             {"b", "cancelled"}
           ]

    assert result(conn, %{
             "operation_id" => "bad-cancel",
             "type" => "cancel_rooms",
             "occurred_on" => "2027-01-03",
             "group_id" => "group-1",
             "room_ids" => ["b", "a", "a"],
             "expected_revision" => 3
           })["code"] == "invalid_rooms"

    assert result(conn, %{
             "operation_id" => "cancel-a",
             "type" => "cancel_rooms",
             "occurred_on" => "2027-01-03",
             "group_id" => "group-1",
             "room_ids" => ["a"],
             "expected_revision" => 3
           })["revision"] == 4

    assert json_response(get(conn, "/api/v1/groups/group-1"), 200)["data"]["status"] ==
             "cancelled"
  end

  test "allocates credit across rooms and restores only the selected room", %{conn: conn} do
    result(conn, open_operation())
    credit_lot(%{source_operation_id: "a-source", remaining_cents: 3})
    credit_lot(%{source_operation_id: "b-source", remaining_cents: 5})

    assert result(conn, %{
             "operation_id" => "apply-1",
             "type" => "apply_hotel_credit",
             "occurred_on" => "2027-01-03",
             "group_id" => "group-1",
             "amount_cents" => 8
           })["outstanding_deposit_cents"] == 2

    group = json_response(get(conn, "/api/v1/groups/group-1"), 200)["data"]

    assert Enum.map(group["rooms"], &{&1["room_id"], &1["credit_paid_cents"]}) == [
             {"a", 4},
             {"b", 4}
           ]

    assert result(conn, %{
             "operation_id" => "cancel-a",
             "type" => "cancel_rooms",
             "occurred_on" => "2027-01-03",
             "group_id" => "group-1",
             "room_ids" => ["a"]
           })["refunded_cents"] == 0

    group = json_response(get(conn, "/api/v1/groups/group-1"), 200)["data"]

    assert {group["deposit_due_cents"], group["credit_paid_cents"],
            group["outstanding_deposit_cents"]} ==
             {6, 4, 2}

    assert json_response(get(conn, "/api/v1/guests/guest-1/credit?on=2027-01-03"), 200)["data"] ==
             %{
               "guest_id" => "guest-1",
               "available_cents" => 4,
               "lots" => [
                 %{
                   "source_operation_id" => "a-source",
                   "remaining_cents" => 3,
                   "expires_on" => "2027-06-01"
                 },
                 %{
                   "source_operation_id" => "b-source",
                   "remaining_cents" => 1,
                   "expires_on" => "2027-06-01"
                 }
               ]
             }
  end

  test "supports target errors, stale revisions, and durable replay for payment reductions", %{
    conn: conn
  } do
    result(conn, open_operation())

    assert result(conn, %{
             "operation_id" => "missing-target",
             "type" => "reduce_cash_payment",
             "payment_operation_id" => "missing",
             "amount_cents" => 1
           })["code"] == "operation_not_found"

    result(conn, %{
      "operation_id" => "pay-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-03",
      "group_id" => "group-1",
      "amount_cents" => 4
    })

    stale = %{
      "operation_id" => "reduce-stale",
      "type" => "reduce_cash_payment",
      "payment_operation_id" => "pay-1",
      "amount_cents" => -1,
      "expected_revision" => 1
    }

    assert result(conn, stale)["code"] == "stale_revision"
    assert result(conn, stale)["code"] == "stale_revision"

    assert result(conn, %{
             "operation_id" => "reduce-too-much",
             "type" => "reduce_cash_payment",
             "payment_operation_id" => "pay-1",
             "amount_cents" => 5,
             "expected_revision" => 2
           })["code"] == "reduction_exceeds_held_cash"

    assert result(conn, %{
             "operation_id" => "reduce-all",
             "type" => "reduce_cash_payment",
             "payment_operation_id" => "pay-1",
             "amount_cents" => 4,
             "expected_revision" => 2
           })["revision"] == 3

    assert result(conn, %{
             "operation_id" => "reduce-again",
             "type" => "reduce_cash_payment",
             "payment_operation_id" => "pay-1",
             "amount_cents" => 1,
             "expected_revision" => 3
           })["code"] == "payment_not_reducible"
  end

  test "distinguishes missing and non-reconcilable payment statements", %{conn: conn} do
    assert json_response(get(conn, "/api/v1/payments/missing"), 404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    result(conn, open_operation())

    assert json_response(get(conn, "/api/v1/payments/open-1"), 422) == %{
             "error" => %{"code" => "payment_not_reconcilable"}
           }
  end

  test "brings durable funding forward in operation commit order", %{conn: conn} do
    result(conn, open_operation())

    result(conn, %{
      "operation_id" => "pay-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2027-02-01",
      "group_id" => "group-1",
      "amount_cents" => 4
    })

    credit_lot(%{source_operation_id: "legacy-credit", remaining_cents: 6})

    result(conn, %{
      "operation_id" => "credit-1",
      "type" => "apply_hotel_credit",
      "occurred_on" => "2027-02-02",
      "group_id" => "group-1",
      "amount_cents" => 6
    })

    group = Repo.get!(Group, "group-1")

    Repo.delete_all(
      from allocation in GroupStay.CashAllocation, where: allocation.group_id == "group-1"
    )

    Repo.delete_all(from allocation in CreditAllocation, where: allocation.group_id == "group-1")
    Repo.update!(Ecto.Changeset.change(group, room_accounting_initialized: false))

    credit_lot =
      Repo.one!(from lot in CreditLot, where: lot.source_operation_id == "legacy-credit")

    Repo.insert!(%CreditAllocation{
      group_id: "group-1",
      credit_lot_id: credit_lot.id,
      amount_cents: 6,
      status: "active"
    })

    rooms = json_response(get(conn, "/api/v1/groups/group-1"), 200)["data"]["rooms"]

    assert Enum.map(rooms, &{&1["room_id"], &1["cash_paid_cents"], &1["credit_paid_cents"]}) == [
             {"a", 4, 0},
             {"b", 0, 6}
           ]
  end

  test "charges back converted credit and tracks entitlement shortfall", %{conn: conn} do
    result(conn, open_operation(%{"group_id" => "source"}))

    result(conn, %{
      "operation_id" => "pay-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-03",
      "group_id" => "source",
      "amount_cents" => 4
    })

    assert result(conn, %{
             "operation_id" => "cancel-source",
             "type" => "cancel_group",
             "occurred_on" => "2027-01-03",
             "group_id" => "source",
             "refund_method" => "hotel_credit"
           })["credit_issued_cents"] == 4

    result(conn, open_operation(%{"operation_id" => "open-target", "group_id" => "target"}))

    assert result(conn, %{
             "operation_id" => "apply-1",
             "type" => "apply_hotel_credit",
             "occurred_on" => "2027-01-04",
             "group_id" => "target",
             "amount_cents" => 4
           })["status"] == "applied"

    assert result(conn, %{
             "operation_id" => "charge-1",
             "type" => "charge_back_payment",
             "payment_operation_id" => "pay-1",
             "expected_revision" => 3
           })["charged_back_cents"] == 4

    assert json_response(get(conn, "/api/v1/ledger?on=2027-01-04"), 200)["data"] == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 4,
             "credit_liability_cents" => 4,
             "credit_shortfall_cents" => 4
           }

    assert json_response(get(conn, "/api/v1/payments/pay-1"), 200)["data"] == %{
             "payment_operation_id" => "pay-1",
             "original_group_id" => "source",
             "recorded_cents" => 4,
             "held_cents" => 0,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 4
           }

    assert result(conn, %{
             "operation_id" => "cancel-target",
             "type" => "cancel_group",
             "occurred_on" => "2027-01-04",
             "group_id" => "target",
             "expected_revision" => 2
           })["revision"] == 3

    assert json_response(get(conn, "/api/v1/ledger?on=2027-01-04"), 200)["data"][
             "credit_shortfall_cents"
           ] == 0
  end
end
