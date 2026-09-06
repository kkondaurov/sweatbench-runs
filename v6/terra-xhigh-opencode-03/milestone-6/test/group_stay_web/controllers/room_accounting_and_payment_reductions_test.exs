defmodule GroupStayWeb.RoomAccountingAndPaymentReductionsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations

  alias GroupStay.Reservations.{
    CashAllocation,
    CashPayment,
    CreditLotEntitlement,
    Group,
    Room,
    RoomCreditAllocation
  }

  defp open_operation(group_id, rooms, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-01-01",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-03-01",
        "departure_on" => "2026-03-02",
        "rate_plan" => "flexible",
        "rooms" => rooms
      },
      overrides
    )
  end

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations})
  end

  test "allocates rooms in order and settles only selected rooms", %{conn: conn} do
    cancellation = %{
      "operation_id" => "cancel-first-room",
      "type" => "cancel_rooms",
      "occurred_on" => "2026-01-03",
      "group_id" => "room-group",
      "room_ids" => ["room-a"]
    }

    response =
      submit(conn, [
        open_operation("room-group", [
          %{"room_id" => "room-a", "nightly_rate_cents" => 1_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 1_000}
        ]),
        %{
          "operation_id" => "room-cash",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-01-02",
          "group_id" => "room-group",
          "amount_cents" => 300
        },
        cancellation
      ])
      |> json_response(200)

    assert Enum.at(response["results"], 2) == %{
             "operation_id" => "cancel-first-room",
             "status" => "applied",
             "group_id" => "room-group",
             "cancelled_room_ids" => ["room-a"],
             "refunded_cents" => 200,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 3
           }

    assert get(build_conn(), "/api/v1/groups/room-group") |> json_response(200) == %{
             "data" => %{
               "group_id" => "room-group",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "booked_on" => "2026-01-01",
               "arrival_on" => "2026-03-01",
               "departure_on" => "2026-03-02",
               "rate_plan" => "flexible",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-02-15",
               "status" => "active",
               "revision" => 3,
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "nightly_rate_cents" => 1_000,
                   "status" => "cancelled",
                   "lodging_total_cents" => 1_000,
                   "deposit_due_cents" => 0,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "room-b",
                   "nightly_rate_cents" => 1_000,
                   "status" => "active",
                   "lodging_total_cents" => 1_000,
                   "deposit_due_cents" => 200,
                   "cash_paid_cents" => 100,
                   "credit_paid_cents" => 0
                 }
               ],
               "lodging_total_cents" => 1_000,
               "deposit_due_cents" => 200,
               "deposit_paid_cents" => 100,
               "cash_paid_cents" => 100,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 100
             }
           }

    assert submit(build_conn(), [cancellation]) |> json_response(200) == %{
             "results" => [Enum.at(response["results"], 2)]
           }

    assert get(build_conn(), "/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 100,
               "cash_refunded_cents" => 200,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
           }
  end

  test "reduces held cash from one payment and reconciles its current disposition", %{conn: conn} do
    reduction = %{
      "operation_id" => "reduce-cash",
      "type" => "reduce_cash_payment",
      "payment_operation_id" => "cash-payment",
      "amount_cents" => 50,
      "expected_revision" => 2
    }

    response =
      submit(conn, [
        open_operation("reduce-group", [%{"room_id" => "room", "nightly_rate_cents" => 1_000}]),
        %{
          "operation_id" => "cash-payment",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-01-02",
          "group_id" => "reduce-group",
          "amount_cents" => 200
        },
        reduction,
        %{
          "operation_id" => "too-large-reduction",
          "type" => "reduce_cash_payment",
          "payment_operation_id" => "cash-payment",
          "amount_cents" => 151
        }
      ])
      |> json_response(200)

    assert Enum.at(response["results"], 2) == %{
             "operation_id" => "reduce-cash",
             "status" => "applied",
             "payment_operation_id" => "cash-payment",
             "group_id" => "reduce-group",
             "amount_cents" => 50,
             "outstanding_deposit_cents" => 50,
             "revision" => 3
           }

    assert Enum.at(response["results"], 3) == %{
             "operation_id" => "too-large-reduction",
             "status" => "rejected",
             "code" => "reduction_exceeds_held_cash"
           }

    assert submit(build_conn(), [reduction]) |> json_response(200) == %{
             "results" => [Enum.at(response["results"], 2)]
           }

    assert get(build_conn(), "/api/v1/payments/cash-payment") |> json_response(200) == %{
             "data" => %{
               "payment_operation_id" => "cash-payment",
               "original_group_id" => "reduce-group",
               "recorded_cents" => 200,
               "held_cents" => 150,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 50,
               "charged_back_cents" => 0
             }
           }
  end

  test "chargebacks revoke converted credit and shortfalls absorb later restoration", %{
    conn: conn
  } do
    response =
      submit(conn, [
        open_operation("credit-source", [
          %{"room_id" => "source-room", "nightly_rate_cents" => 500}
        ]),
        %{
          "operation_id" => "converted-payment",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-01-02",
          "group_id" => "credit-source",
          "amount_cents" => 100
        },
        %{
          "operation_id" => "convert-payment",
          "type" => "cancel_group",
          "occurred_on" => "2026-01-03",
          "group_id" => "credit-source",
          "refund_method" => "hotel_credit"
        },
        open_operation("credit-target", [
          %{"room_id" => "target-room", "nightly_rate_cents" => 550}
        ]),
        %{
          "operation_id" => "apply-converted-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-01-04",
          "group_id" => "credit-target",
          "amount_cents" => 110
        },
        %{
          "operation_id" => "chargeback-payment",
          "type" => "charge_back_payment",
          "payment_operation_id" => "converted-payment",
          "expected_revision" => 3
        }
      ])
      |> json_response(200)

    assert Enum.at(response["results"], 5) == %{
             "operation_id" => "chargeback-payment",
             "status" => "applied",
             "payment_operation_id" => "converted-payment",
             "group_id" => "credit-source",
             "charged_back_cents" => 100,
             "outstanding_deposit_cents" => 0,
             "revision" => 4
           }

    assert get(build_conn(), "/api/v1/payments/converted-payment") |> json_response(200) == %{
             "data" => %{
               "payment_operation_id" => "converted-payment",
               "original_group_id" => "credit-source",
               "recorded_cents" => 100,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 100
             }
           }

    assert get(build_conn(), "/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 100,
               "credit_liability_cents" => 110,
               "credit_shortfall_cents" => 110
             }
           }

    assert submit(build_conn(), [
             %{
               "operation_id" => "cancel-credit-target",
               "type" => "cancel_group",
               "occurred_on" => "2026-01-05",
               "group_id" => "credit-target"
             }
           ])
           |> json_response(200)
           |> get_in(["results", Access.at(0), "status"]) == "applied"

    assert get(build_conn(), "/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 100,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
           }
  end

  test "rebuilds legacy room allocations in durable record order", %{conn: conn} do
    submit(conn, [
      open_operation("credit-source", [%{"room_id" => "source-room", "nightly_rate_cents" => 500}]),
      %{
        "operation_id" => "source-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-02",
        "group_id" => "credit-source",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "source-cancellation",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-03",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      },
      open_operation("migration-target", [
        %{"room_id" => "first", "nightly_rate_cents" => 1_000},
        %{"room_id" => "second", "nightly_rate_cents" => 1_000}
      ]),
      %{
        "operation_id" => "credit-before-cash",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-01-04",
        "group_id" => "migration-target",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "cash-after-credit",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-04",
        "group_id" => "migration-target",
        "amount_cents" => 300
      }
    ])
    |> json_response(200)

    group = Repo.get_by!(Group, group_id: "migration-target")

    Repo.delete_all(from allocation in CashAllocation, where: allocation.group_db_id == ^group.id)

    Repo.delete_all(
      from allocation in RoomCreditAllocation,
        where: allocation.group_db_id == ^group.id
    )

    Repo.update_all(
      from(room in Room, where: room.group_db_id == ^group.id),
      set: [cash_paid_cents: 0, credit_paid_cents: 0]
    )

    assert get(build_conn(), "/api/v1/groups/migration-target")
           |> json_response(200)
           |> get_in(["data", "rooms"]) == [
             %{
               "room_id" => "first",
               "nightly_rate_cents" => 1_000,
               "status" => "active",
               "lodging_total_cents" => 1_000,
               "deposit_due_cents" => 200,
               "cash_paid_cents" => 100,
               "credit_paid_cents" => 100
             },
             %{
               "room_id" => "second",
               "nightly_rate_cents" => 1_000,
               "status" => "active",
               "lodging_total_cents" => 1_000,
               "deposit_due_cents" => 200,
               "cash_paid_cents" => 200,
               "credit_paid_cents" => 0
             }
           ]
  end

  test "backfills settled durable payments with reconcilable dispositions", %{conn: conn} do
    submit(conn, [
      open_operation("historical-group", [
        %{"room_id" => "historical-room", "nightly_rate_cents" => 500}
      ]),
      %{
        "operation_id" => "historical-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-02",
        "group_id" => "historical-group",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "historical-cancellation",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-03",
        "group_id" => "historical-group",
        "refund_method" => "hotel_credit"
      }
    ])
    |> json_response(200)

    Repo.delete_all(
      from entitlement in CreditLotEntitlement,
        where: entitlement.payment_operation_id == "historical-payment"
    )

    Repo.delete_all(
      from payment in CashPayment,
        where: payment.payment_operation_id == "historical-payment"
    )

    assert {:ok, _} = Reservations.backfill_legacy_room_accounting()

    assert get(build_conn(), "/api/v1/payments/historical-payment") |> json_response(200) == %{
             "data" => %{
               "payment_operation_id" => "historical-payment",
               "original_group_id" => "historical-group",
               "recorded_cents" => 100,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 100,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }
           }

    assert submit(build_conn(), [
             %{
               "operation_id" => "charge-historical-payment",
               "type" => "charge_back_payment",
               "payment_operation_id" => "historical-payment"
             }
           ])
           |> json_response(200)
           |> get_in(["results", Access.at(0), "charged_back_cents"]) == 100
  end
end
