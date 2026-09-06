defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-group",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-1",
        "guest_id" => "guest-1",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 100},
          %{"room_id" => "room-b", "nightly_rate_cents" => 100}
        ]
      },
      overrides
    )
  end

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  test "allocates funding to rooms in room order and exposes room accounting", %{conn: conn} do
    assert %{"results" => [%{"status" => "applied"}, %{"revision" => 2}]} =
             submit(conn, [
               open_operation(),
               %{
                 "operation_id" => "payment-1",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-1",
                 "amount_cents" => 15
               }
             ])

    assert %{"data" => data} = conn |> get("/api/v1/groups/group-1") |> json_response(200)

    assert data["rooms"] == [
             %{
               "room_id" => "room-a",
               "nightly_rate_cents" => 100,
               "lodging_total_cents" => 100,
               "status" => "active",
               "deposit_due_cents" => 20,
               "cash_paid_cents" => 15,
               "credit_paid_cents" => 0
             },
             %{
               "room_id" => "room-b",
               "nightly_rate_cents" => 100,
               "lodging_total_cents" => 100,
               "status" => "active",
               "deposit_due_cents" => 20,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
             }
           ]

    assert data["deposit_paid_cents"] == 15
    assert data["outstanding_deposit_cents"] == 25
  end

  test "cancels selected rooms and settles only their funding", %{conn: conn} do
    assert %{"results" => [%{}, %{}]} =
             submit(conn, [
               open_operation(),
               %{
                 "operation_id" => "payment-1",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-1",
                 "amount_cents" => 30
               }
             ])

    assert %{
             "results" => [
               %{"cancelled_room_ids" => ["room-a"], "refunded_cents" => 20, "revision" => 3}
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "cancel-room-a",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2026-11-01",
                 "group_id" => "group-1",
                 "room_ids" => ["room-a"]
               }
             ])

    assert %{"data" => data} = conn |> get("/api/v1/groups/group-1") |> json_response(200)
    assert data["status"] == "active"
    assert data["lodging_total_cents"] == 100
    assert data["deposit_due_cents"] == 20
    assert data["cash_paid_cents"] == 10
    assert data["outstanding_deposit_cents"] == 10

    assert Enum.find(data["rooms"], &(&1["room_id"] == "room-a")) == %{
             "room_id" => "room-a",
             "nightly_rate_cents" => 100,
             "lodging_total_cents" => 100,
             "status" => "cancelled",
             "deposit_due_cents" => 20,
             "cash_paid_cents" => 20,
             "credit_paid_cents" => 0
           }

    assert %{"data" => payment} =
             conn |> get("/api/v1/payments/payment-1") |> json_response(200)

    assert payment == %{
             "payment_operation_id" => "payment-1",
             "original_group_id" => "group-1",
             "recorded_cents" => 30,
             "held_cents" => 10,
             "refunded_cents" => 20,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 0
           }
  end

  test "reduces a payment from the reverse room fill order", %{conn: conn} do
    submit(conn, [open_operation()])

    submit(conn, [
      %{
        "operation_id" => "payment-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-1",
        "amount_cents" => 30
      }
    ])

    assert %{
             "results" => [
               %{"amount_cents" => 25, "outstanding_deposit_cents" => 35, "revision" => 3}
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "reduce-1",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "payment-1",
                 "amount_cents" => 25,
                 "expected_revision" => 2
               }
             ])

    assert %{"data" => %{"cash_held_cents" => 5, "cash_reduced_cents" => 25}} =
             conn |> get("/api/v1/ledger") |> json_response(200)
  end

  test "chargeback moves all remaining payment dispositions and revokes credit", %{conn: conn} do
    submit(conn, [open_operation()])

    submit(conn, [
      %{
        "operation_id" => "payment-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-1",
        "amount_cents" => 20
      },
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-1",
        "refund_method" => "hotel_credit"
      }
    ])

    assert %{"results" => [%{"charged_back_cents" => 20, "revision" => 4}]} =
             submit(conn, [
               %{
                 "operation_id" => "chargeback-1",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "payment-1",
                 "expected_revision" => 3
               }
             ])

    assert %{"data" => %{"available_cents" => 0}} =
             conn |> get("/api/v1/guests/guest-1/credit?on=2026-11-01") |> json_response(200)

    assert %{"data" => ledger} = conn |> get("/api/v1/ledger") |> json_response(200)
    assert ledger["cash_held_cents"] == 0
    assert ledger["cash_converted_to_credit_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 20
  end

  test "rejects invalid room selections atomically and distinguishes payment reads", %{conn: conn} do
    submit(conn, [open_operation()])

    assert %{"results" => [%{"code" => "invalid_rooms"}]} =
             submit(conn, [
               %{
                 "operation_id" => "bad-cancel",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2026-11-01",
                 "group_id" => "group-1",
                 "room_ids" => ["room-a", "room-a"]
               }
             ])

    assert %{"data" => %{"revision" => 1, "status" => "active"}} =
             conn |> get("/api/v1/groups/group-1") |> json_response(200)

    assert %{"error" => %{"code" => "operation_not_found"}} =
             conn |> get("/api/v1/payments/missing") |> json_response(404)

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [
               %{
                 "operation_id" => "not-a-payment",
                 "type" => "reschedule_group",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-1",
                 "new_arrival_on" => "2026-12-20"
               }
             ])

    assert %{"error" => %{"code" => "payment_not_reconcilable"}} =
             conn |> get("/api/v1/payments/not-a-payment") |> json_response(422)
  end

  test "restores only selected credit allocations without a second bonus", %{conn: conn} do
    submit(conn, [
      open_operation(%{"group_id" => "credit-source", "operation_id" => "open-source"}),
      open_operation(%{"group_id" => "credit-target", "operation_id" => "open-target"})
    ])

    submit(conn, [
      %{
        "operation_id" => "source-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "credit-source",
        "amount_cents" => 20
      },
      %{
        "operation_id" => "source-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      },
      %{
        "operation_id" => "apply-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-02",
        "group_id" => "credit-target",
        "amount_cents" => 20
      }
    ])

    assert %{"results" => [%{"credit_issued_cents" => 0}]} =
             submit(conn, [
               %{
                 "operation_id" => "cancel-target",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2026-11-03",
                 "group_id" => "credit-target",
                 "room_ids" => ["room-a"]
               }
             ])

    assert %{"data" => %{"available_cents" => 22}} =
             conn |> get("/api/v1/guests/guest-1/credit?on=2026-11-03") |> json_response(200)
  end

  test "tracks a credit shortfall until applied credit is consumed", %{conn: conn} do
    submit(conn, [
      open_operation(%{"group_id" => "credit-source", "operation_id" => "open-source"})
    ])

    submit(conn, [
      %{
        "operation_id" => "source-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "credit-source",
        "amount_cents" => 20
      },
      %{
        "operation_id" => "source-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      },
      open_operation(%{
        "operation_id" => "open-target",
        "group_id" => "credit-target",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 110}]
      }),
      %{
        "operation_id" => "apply-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-02",
        "group_id" => "credit-target",
        "amount_cents" => 22
      }
    ])

    assert %{"results" => [%{"revision" => 4}]} =
             submit(conn, [
               %{
                 "operation_id" => "chargeback-source",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "source-payment",
                 "expected_revision" => 3
               }
             ])

    assert %{"data" => %{"credit_liability_cents" => 22, "credit_shortfall_cents" => 22}} =
             conn |> get("/api/v1/ledger?on=2026-11-03") |> json_response(200)

    assert %{"results" => [%{"retained_cents" => 0}]} =
             submit(conn, [
               %{
                 "operation_id" => "consume-shortfall",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-12-01",
                 "group_id" => "credit-target",
                 "expected_revision" => 2
               }
             ])

    assert %{"data" => %{"credit_liability_cents" => 0, "credit_shortfall_cents" => 0}} =
             conn |> get("/api/v1/ledger?on=2026-12-01") |> json_response(200)
  end

  test "assigns one bonus across multiple payments and chargebacks the payment portion", %{
    conn: conn
  } do
    submit(conn, [open_operation(%{"group_id" => "group-1", "operation_id" => "open-group"})])

    submit(conn, [
      %{
        "operation_id" => "payment-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-1",
        "amount_cents" => 10
      },
      %{
        "operation_id" => "payment-2",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-1",
        "amount_cents" => 10
      },
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-1",
        "refund_method" => "hotel_credit"
      }
    ])

    assert %{"data" => %{"available_cents" => 22}} =
             conn |> get("/api/v1/guests/guest-1/credit?on=2026-11-01") |> json_response(200)

    assert %{"results" => [%{"charged_back_cents" => 10}]} =
             submit(conn, [
               %{
                 "operation_id" => "chargeback-1",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "payment-1",
                 "expected_revision" => 4
               }
             ])

    assert %{"data" => %{"available_cents" => 11}} =
             conn |> get("/api/v1/guests/guest-1/credit?on=2026-11-01") |> json_response(200)

    assert %{"data" => payment} =
             conn |> get("/api/v1/payments/payment-1") |> json_response(200)

    assert payment["converted_to_credit_cents"] == 0
    assert payment["charged_back_cents"] == 10
  end

  test "replays new operations exactly and checks stale corrections first", %{conn: conn} do
    submit(conn, [open_operation()])

    payment = %{
      "operation_id" => "payment-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1",
      "amount_cents" => 20
    }

    submit(conn, [payment])

    reduction = %{
      "operation_id" => "reduce-1",
      "type" => "reduce_cash_payment",
      "payment_operation_id" => "payment-1",
      "amount_cents" => 5,
      "expected_revision" => 2
    }

    first = submit(conn, [reduction])
    assert ^first = submit(conn, [reduction])

    assert %{"results" => [%{"code" => "stale_revision", "actual_revision" => 3}]} =
             submit(conn, [
               %{
                 "operation_id" => "stale-reduction",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "payment-1",
                 "amount_cents" => -1,
                 "expected_revision" => 2
               }
             ])

    assert %{"results" => [%{"code" => "stale_revision", "actual_revision" => 3}]} =
             submit(conn, [
               %{
                 "operation_id" => "stale-reduction-2",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "payment-1",
                 "amount_cents" => -1,
                 "expected_revision" => 2
               }
             ])

    assert %{"data" => %{"revision" => 3}} =
             conn |> get("/api/v1/groups/group-1") |> json_response(200)
  end

  test "replays selected cancellations and chargebacks without reapplying them", %{conn: conn} do
    submit(conn, [open_operation()])

    submit(conn, [
      %{
        "operation_id" => "payment-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-1",
        "amount_cents" => 20
      }
    ])

    cancellation = %{
      "operation_id" => "cancel-room",
      "type" => "cancel_rooms",
      "occurred_on" => "2026-11-01",
      "group_id" => "group-1",
      "room_ids" => ["room-a"]
    }

    first_cancellation = submit(conn, [cancellation])
    assert ^first_cancellation = submit(conn, [cancellation])

    chargeback = %{
      "operation_id" => "chargeback-1",
      "type" => "charge_back_payment",
      "payment_operation_id" => "payment-1",
      "expected_revision" => 3
    }

    first_chargeback = submit(conn, [chargeback])
    assert ^first_chargeback = submit(conn, [chargeback])

    assert %{"data" => %{"revision" => 4, "cash_paid_cents" => 0}} =
             conn |> get("/api/v1/groups/group-1") |> json_response(200)
  end

  test "keeps the ledger cash partition balanced across a partial refund and chargeback", %{
    conn: conn
  } do
    submit(conn, [open_operation()])

    submit(conn, [
      %{
        "operation_id" => "payment-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-1",
        "amount_cents" => 30
      }
    ])

    submit(conn, [
      %{
        "operation_id" => "cancel-room",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-1",
        "room_ids" => ["room-a"]
      }
    ])

    assert %{"results" => [%{"charged_back_cents" => 30}]} =
             submit(conn, [
               %{
                 "operation_id" => "chargeback-1",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "payment-1",
                 "expected_revision" => 3
               }
             ])

    assert %{"data" => ledger} = conn |> get("/api/v1/ledger") |> json_response(200)
    assert ledger["cash_held_cents"] == 0
    assert ledger["cash_refunded_cents"] == 0
    assert ledger["cash_retained_cents"] == 0
    assert ledger["cash_reduced_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 30

    assert %{"data" => payment} =
             conn |> get("/api/v1/payments/payment-1") |> json_response(200)

    assert payment["recorded_cents"] ==
             payment["held_cents"] + payment["refunded_cents"] +
               payment["retained_cents"] + payment["converted_to_credit_cents"] +
               payment["reduced_cents"] + payment["charged_back_cents"]
  end
end
