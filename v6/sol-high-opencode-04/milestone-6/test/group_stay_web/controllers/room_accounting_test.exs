defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  test "allocates funding by room and settles selected rooms in original order", %{conn: conn} do
    operations = [
      open_operation(),
      payment_operation("pay-1", "group-1", 9_500),
      operation("cancel-rooms", "cancel_rooms", %{
        "group_id" => "group-1",
        "room_ids" => ["room-a"]
      })
    ]

    conn = post(conn, "/api/v1/partner-batches", %{operations: operations})

    assert %{"results" => [_, _, cancelled]} = json_response(conn, 200)

    assert cancelled == %{
             "operation_id" => "cancel-rooms",
             "status" => "applied",
             "group_id" => "group-1",
             "cancelled_room_ids" => ["room-a"],
             "refunded_cents" => 9_000,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 3
           }

    assert %{
             "data" => %{
               "status" => "active",
               "lodging_total_cents" => 52_500,
               "deposit_due_cents" => 10_500,
               "deposit_paid_cents" => 500,
               "outstanding_deposit_cents" => 10_000,
               "rooms" => [room_a, room_b]
             }
           } = json_response(get(build_conn(), "/api/v1/groups/group-1"), 200)

    assert %{
             "status" => "cancelled",
             "lodging_total_cents" => 45_000,
             "deposit_due_cents" => 9_000,
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 0
           } = room_a

    assert %{
             "status" => "active",
             "lodging_total_cents" => 52_500,
             "deposit_due_cents" => 10_500,
             "cash_paid_cents" => 500,
             "credit_paid_cents" => 0
           } = room_b

    assert %{
             "data" => %{
               "recorded_cents" => 9_500,
               "held_cents" => 500,
               "refunded_cents" => 9_000
             }
           } = json_response(get(build_conn(), "/api/v1/payments/pay-1"), 200)
  end

  test "rejects invalid room selections atomically and returns selected ids in group order", %{
    conn: conn
  } do
    operations = [
      open_operation(),
      operation("invalid", "cancel_rooms", %{
        "group_id" => "group-1",
        "room_ids" => ["room-a", "room-a"]
      }),
      operation("all-rooms", "cancel_rooms", %{
        "group_id" => "group-1",
        "room_ids" => ["room-b", "room-a"]
      })
    ]

    conn = post(conn, "/api/v1/partner-batches", %{operations: operations})

    assert %{"results" => [_, invalid, cancelled]} = json_response(conn, 200)
    assert invalid["code"] == "invalid_rooms"
    assert invalid["group_id"] == "group-1"
    assert cancelled["cancelled_room_ids"] == ["room-a", "room-b"]
    assert cancelled["revision"] == 2
  end

  test "reduces only target payment cash in reverse fill order", %{conn: conn} do
    operations = [
      open_operation(),
      payment_operation("pay-1", "group-1", 9_500),
      operation("reduce-1", "reduce_cash_payment", %{
        "payment_operation_id" => "pay-1",
        "amount_cents" => 600
      })
    ]

    conn = post(conn, "/api/v1/partner-batches", %{operations: operations})
    assert %{"results" => [_, _, reduced]} = json_response(conn, 200)

    assert reduced == %{
             "operation_id" => "reduce-1",
             "status" => "applied",
             "payment_operation_id" => "pay-1",
             "group_id" => "group-1",
             "amount_cents" => 600,
             "outstanding_deposit_cents" => 10_600,
             "revision" => 3
           }

    assert %{"data" => %{"rooms" => [room_a, room_b]}} =
             json_response(get(build_conn(), "/api/v1/groups/group-1"), 200)

    assert room_a["cash_paid_cents"] == 8_900
    assert room_b["cash_paid_cents"] == 0

    assert %{
             "data" => %{
               "recorded_cents" => 9_500,
               "held_cents" => 8_900,
               "reduced_cents" => 600,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "charged_back_cents" => 0
             }
           } = json_response(get(build_conn(), "/api/v1/payments/pay-1"), 200)

    next =
      operation("reduce-rest", "reduce_cash_payment", %{
        "payment_operation_id" => "pay-1",
        "amount_cents" => 8_900
      })

    conn = post(build_conn(), "/api/v1/partner-batches", %{operations: [next]})
    assert %{"results" => [%{"status" => "applied", "revision" => 4}]} = json_response(conn, 200)

    again =
      operation("reduce-again", "reduce_cash_payment", %{
        "payment_operation_id" => "pay-1",
        "amount_cents" => 1
      })

    conn = post(build_conn(), "/api/v1/partner-batches", %{operations: [again]})
    assert %{"results" => [%{"code" => "payment_not_reducible"}]} = json_response(conn, 200)
  end

  test "charges back settled cash and preserves the original payment result", %{conn: conn} do
    payment = payment_operation("pay-1", "group-1", 5_000)

    operations = [
      open_operation(),
      payment,
      operation("cancel-1", "cancel_group", %{"group_id" => "group-1"}),
      operation("chargeback-1", "charge_back_payment", %{
        "payment_operation_id" => "pay-1",
        "expected_revision" => 3
      })
    ]

    conn = post(conn, "/api/v1/partner-batches", %{operations: operations})
    assert %{"results" => [_, original_payment, _, chargeback]} = json_response(conn, 200)

    assert chargeback == %{
             "operation_id" => "chargeback-1",
             "status" => "applied",
             "payment_operation_id" => "pay-1",
             "group_id" => "group-1",
             "charged_back_cents" => 5_000,
             "outstanding_deposit_cents" => 0,
             "revision" => 4
           }

    assert %{
             "data" => %{
               "recorded_cents" => 5_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "charged_back_cents" => 5_000
             }
           } = json_response(get(build_conn(), "/api/v1/payments/pay-1"), 200)

    assert %{
             "data" => %{
               "cash_refunded_cents" => 0,
               "cash_charged_back_cents" => 5_000
             }
           } = json_response(get(build_conn(), "/api/v1/ledger"), 200)

    conn = post(build_conn(), "/api/v1/partner-batches", %{operations: [payment]})
    assert json_response(conn, 200) == %{"results" => [original_payment]}
  end

  test "tracks credit shortfall and absorbs restored credit after a converted payment chargeback",
       %{
         conn: conn
       } do
    operations = [
      open_operation(),
      payment_operation("pay-source", "group-1", 1_000),
      operation("convert", "cancel_group", %{
        "group_id" => "group-1",
        "refund_method" => "hotel_credit"
      }),
      open_operation(%{
        "operation_id" => "open-target",
        "group_id" => "target",
        "guest_id" => "guest-1"
      }),
      operation("apply-credit", "apply_hotel_credit", %{
        "group_id" => "target",
        "amount_cents" => 1_100
      }),
      operation("chargeback", "charge_back_payment", %{
        "payment_operation_id" => "pay-source",
        "expected_revision" => 3
      })
    ]

    conn = post(conn, "/api/v1/partner-batches", %{operations: operations})
    assert %{"results" => results} = json_response(conn, 200)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{
             "data" => %{
               "cash_converted_to_credit_cents" => 0,
               "cash_charged_back_cents" => 1_000,
               "credit_liability_cents" => 1_100,
               "credit_shortfall_cents" => 1_100
             }
           } = json_response(get(build_conn(), "/api/v1/ledger?on=2026-10-03"), 200)

    assert %{"data" => %{"revision" => 2, "credit_paid_cents" => 1_100}} =
             json_response(get(build_conn(), "/api/v1/groups/target"), 200)

    restore = operation("cancel-target", "cancel_group", %{"group_id" => "target"})
    conn = post(build_conn(), "/api/v1/partner-batches", %{operations: [restore]})

    assert %{"results" => [%{"status" => "applied", "refunded_cents" => 0}]} =
             json_response(conn, 200)

    assert %{
             "data" => %{
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
           } = json_response(get(build_conn(), "/api/v1/ledger?on=2026-10-03"), 200)
  end

  test "payment reads distinguish missing and non-reconcilable operations", %{conn: conn} do
    conn = post(conn, "/api/v1/partner-batches", %{operations: [open_operation()]})
    assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

    assert json_response(get(build_conn(), "/api/v1/payments/missing"), 404) ==
             %{"error" => %{"code" => "operation_not_found"}}

    assert json_response(get(build_conn(), "/api/v1/payments/open-1"), 422) ==
             %{"error" => %{"code" => "payment_not_reconcilable"}}
  end

  test "backfills legacy cash ahead of durable payment funding", %{conn: conn} do
    operations = [open_operation(), payment_operation("pay-1", "group-1", 2_000)]
    conn = post(conn, "/api/v1/partner-batches", %{operations: operations})

    assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
             json_response(conn, 200)

    group = GroupStay.Repo.get_by!(GroupStay.Group, group_id: "group-1")
    GroupStay.Repo.delete_all(GroupStay.RoomFundingAllocation)
    GroupStay.Repo.delete_all(GroupStay.CashPayment)

    GroupStay.Repo.update_all(from(g in GroupStay.Group, where: g.id == ^group.id),
      set: [deposit_paid_cents: 6_000, accounting_initialized: false]
    )

    GroupStay.Operations.backfill_room_accounting()

    allocations =
      GroupStay.Repo.all(
        from(a in GroupStay.RoomFundingAllocation,
          order_by: a.id,
          select: {a.operation_id, a.amount_cents}
        )
      )

    assert allocations == [{nil, 4_000}, {"pay-1", 2_000}]

    assert %{
             "data" => %{
               "recorded_cents" => 2_000,
               "held_cents" => 2_000,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }
           } = json_response(get(build_conn(), "/api/v1/payments/pay-1"), 200)
  end

  test "assigns a converted lot's rounded entitlement across payments", %{conn: conn} do
    operations = [
      open_operation(),
      payment_operation("pay-1", "group-1", 5),
      payment_operation("pay-2", "group-1", 5),
      operation("convert", "cancel_group", %{
        "group_id" => "group-1",
        "refund_method" => "hotel_credit"
      })
    ]

    conn = post(conn, "/api/v1/partner-batches", %{operations: operations})

    assert %{"results" => [_, _, _, %{"credit_issued_cents" => 11}]} =
             json_response(conn, 200)

    charge_first =
      operation("charge-first", "charge_back_payment", %{
        "payment_operation_id" => "pay-1",
        "expected_revision" => 4
      })

    conn = post(build_conn(), "/api/v1/partner-batches", %{operations: [charge_first]})

    assert %{"results" => [%{"charged_back_cents" => 5, "revision" => 5}]} =
             json_response(conn, 200)

    assert %{
             "data" => %{
               "available_cents" => 5,
               "lots" => [%{"remaining_cents" => 5}]
             }
           } =
             json_response(get(build_conn(), "/api/v1/guests/guest-1/credit?on=2026-10-03"), 200)

    charge_second =
      operation("charge-second", "charge_back_payment", %{
        "payment_operation_id" => "pay-2",
        "expected_revision" => 5
      })

    conn = post(build_conn(), "/api/v1/partner-batches", %{operations: [charge_second]})

    assert %{"results" => [%{"charged_back_cents" => 5, "revision" => 6}]} =
             json_response(conn, 200)

    assert %{"data" => %{"credit_liability_cents" => 0, "cash_charged_back_cents" => 10}} =
             json_response(get(build_conn(), "/api/v1/ledger?on=2026-10-03"), 200)
  end

  test "retries a reduction exactly without removing cash twice", %{conn: conn} do
    reduction =
      operation("reduce", "reduce_cash_payment", %{
        "payment_operation_id" => "pay-1",
        "amount_cents" => 100
      })

    operations = [open_operation(), payment_operation("pay-1", "group-1", 1_000), reduction]
    conn = post(conn, "/api/v1/partner-batches", %{operations: operations})
    assert %{"results" => [_, _, original]} = json_response(conn, 200)

    later =
      operation("reduce-later", "reduce_cash_payment", %{
        "payment_operation_id" => "pay-1",
        "amount_cents" => 200
      })

    conn = post(build_conn(), "/api/v1/partner-batches", %{operations: [later, reduction]})
    assert %{"results" => [%{"revision" => 4}, retried]} = json_response(conn, 200)
    assert retried == original

    assert %{"data" => %{"held_cents" => 700, "reduced_cents" => 300}} =
             json_response(get(build_conn(), "/api/v1/payments/pay-1"), 200)

    conflict = Map.put(reduction, "amount_cents", 50)
    conn = post(build_conn(), "/api/v1/partner-batches", %{operations: [conflict]})
    assert %{"results" => [%{"code" => "operation_id_conflict"}]} = json_response(conn, 200)
  end

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-1",
        "guest_id" => "guest-1",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp payment_operation(operation_id, group_id, amount) do
    operation(operation_id, "record_cash_payment", %{
      "group_id" => group_id,
      "amount_cents" => amount
    })
  end

  defp operation(operation_id, type, fields) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => type,
        "occurred_on" => "2026-10-03"
      },
      fields
    )
  end
end
