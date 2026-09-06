defmodule GroupStayWeb.DepositTransferTest do
  use GroupStayWeb.ConnCase

  defp open_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "open-source",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "source",
        "guest_id" => "guest-1",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-12",
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

  defp payment(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp transfer(operation_id, source_group_id, destination_group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents
    }
  end

  test "moves cash in reverse allocation order and exposes transferred payment holdings", %{
    conn: conn
  } do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 1}]} =
             submit(conn, [
               open_operation(%{"operation_id" => "open-source", "group_id" => "source"}),
               open_operation(%{
                 "operation_id" => "open-destination",
                 "group_id" => "destination"
               })
             ])

    assert %{"results" => [%{"revision" => 2}]} =
             submit(conn, [payment("payment-1", "source", 60)])

    operation = transfer("transfer-1", "source", "destination", 50)

    assert %{"results" => [result]} = submit(conn, [operation])

    assert result == %{
             "operation_id" => "transfer-1",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 50,
             "source_outstanding_deposit_cents" => 70,
             "destination_outstanding_deposit_cents" => 30,
             "source_revision" => 3,
             "destination_revision" => 2
           }

    assert %{"data" => source} = conn |> get("/api/v1/groups/source") |> json_response(200)

    assert source["rooms"] == [
             %{
               "room_id" => "room-a",
               "nightly_rate_cents" => 100,
               "lodging_total_cents" => 200,
               "status" => "active",
               "deposit_due_cents" => 40,
               "cash_paid_cents" => 10,
               "credit_paid_cents" => 0
             },
             %{
               "room_id" => "room-b",
               "nightly_rate_cents" => 100,
               "lodging_total_cents" => 200,
               "status" => "active",
               "deposit_due_cents" => 40,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
             }
           ]

    assert %{"data" => destination} =
             conn |> get("/api/v1/groups/destination") |> json_response(200)

    assert Enum.map(destination["rooms"], & &1["cash_paid_cents"]) == [40, 10]

    assert %{"data" => payment_statement} =
             conn |> get("/api/v1/payments/payment-1") |> json_response(200)

    assert payment_statement["held_cents"] == 60

    assert payment_statement["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 50},
             %{"group_id" => "source", "amount_cents" => 10}
           ]

    assert submit(conn, [operation]) == %{"results" => [result]}

    assert %{"data" => %{"revision" => 3}} =
             conn |> get("/api/v1/groups/source") |> json_response(200)

    assert %{"data" => %{"revision" => 2}} =
             conn |> get("/api/v1/groups/destination") |> json_response(200)
  end

  test "moves credit without revaluing or resuming its lot, then restores it once", %{conn: conn} do
    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [
               open_operation(%{
                 "operation_id" => "open-credit-source",
                 "group_id" => "credit-source"
               })
             ])

    assert %{"results" => [%{"status" => "applied"}, %{"credit_issued_cents" => 22}]} =
             submit(conn, [
               payment("credit-payment", "credit-source", 20),
               %{
                 "operation_id" => "credit-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-01",
                 "group_id" => "credit-source",
                 "refund_method" => "hotel_credit"
               }
             ])

    assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
             submit(conn, [
               open_operation(%{
                 "operation_id" => "open-source-to-move",
                 "group_id" => "source-to-move"
               }),
               open_operation(%{
                 "operation_id" => "open-destination",
                 "group_id" => "destination"
               })
             ])

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [
               %{
                 "operation_id" => "apply-source-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2026-11-02",
                 "group_id" => "source-to-move",
                 "amount_cents" => 20
               }
             ])

    assert %{"data" => %{"available_cents" => 2}} =
             conn |> get("/api/v1/guests/guest-1/credit?on=2026-11-02") |> json_response(200)

    assert %{"results" => [%{"amount_cents" => 20, "source_revision" => 3}]} =
             submit(conn, [transfer("credit-transfer", "source-to-move", "destination", 20)])

    assert %{"data" => %{"credit_paid_cents" => 0, "revision" => 3}} =
             conn |> get("/api/v1/groups/source-to-move") |> json_response(200)

    assert %{"data" => %{"credit_paid_cents" => 20, "revision" => 2}} =
             conn |> get("/api/v1/groups/destination") |> json_response(200)

    assert %{"results" => [%{"credit_issued_cents" => 0}]} =
             submit(conn, [
               %{
                 "operation_id" => "cancel-destination",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-03",
                 "group_id" => "destination"
               }
             ])

    assert %{"data" => %{"available_cents" => 22}} =
             conn |> get("/api/v1/guests/guest-1/credit?on=2026-11-03") |> json_response(200)
  end

  test "preserves the draw order and provenance when a transfer spans cash and credit", %{
    conn: conn
  } do
    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [
               open_operation(%{
                 "operation_id" => "open-credit-seed",
                 "group_id" => "credit-seed"
               })
             ])

    assert %{"results" => [%{"status" => "applied"}, %{"credit_issued_cents" => 22}]} =
             submit(conn, [
               payment("seed-payment", "credit-seed", 20),
               %{
                 "operation_id" => "seed-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-01",
                 "group_id" => "credit-seed",
                 "refund_method" => "hotel_credit"
               }
             ])

    assert %{"results" => [%{}, %{}]} =
             submit(conn, [
               open_operation(%{"group_id" => "source"}),
               open_operation(%{
                 "operation_id" => "open-destination",
                 "group_id" => "destination"
               })
             ])

    assert %{"results" => [%{"revision" => 2}, %{"revision" => 3}]} =
             submit(conn, [
               payment("cash-payment", "source", 20),
               %{
                 "operation_id" => "credit-payment",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2026-11-02",
                 "group_id" => "source",
                 "amount_cents" => 20
               }
             ])

    assert %{"results" => [%{"amount_cents" => 30}]} =
             submit(conn, [transfer("mixed-transfer", "source", "destination", 30)])

    assert %{"data" => source} = conn |> get("/api/v1/groups/source") |> json_response(200)

    assert Enum.map(source["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) == [
             {10, 0},
             {0, 0}
           ]

    assert %{"data" => destination} =
             conn |> get("/api/v1/groups/destination") |> json_response(200)

    assert Enum.map(destination["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) == [
             {10, 20},
             {0, 0}
           ]

    assert %{
             "data" => %{
               "held_cents" => 20,
               "held_by_group" => [
                 %{"group_id" => "destination", "amount_cents" => 10},
                 %{"group_id" => "source", "amount_cents" => 10}
               ]
             }
           } =
             conn |> get("/api/v1/payments/cash-payment") |> json_response(200)

    assert %{"data" => %{"available_cents" => 2}} =
             conn |> get("/api/v1/guests/guest-1/credit?on=2026-11-02") |> json_response(200)
  end

  test "checks both revisions before transfer validation and reports missing groups in order", %{
    conn: conn
  } do
    assert %{"results" => [%{}, %{}]} =
             submit(conn, [
               open_operation(%{"group_id" => "source"}),
               open_operation(%{
                 "operation_id" => "open-destination",
                 "group_id" => "destination"
               })
             ])

    assert %{"results" => [%{"revision" => 2}, %{"revision" => 2}]} =
             submit(conn, [
               payment("source-payment", "source", 1),
               payment("dest-payment", "destination", 1)
             ])

    assert %{
             "results" => [
               %{"code" => "stale_revision", "group_id" => "source", "actual_revision" => 2}
             ]
           } =
             submit(conn, [
               Map.merge(transfer("stale-source", "source", "destination", 0), %{
                 "expected_revision" => 1,
                 "destination_expected_revision" => 1
               })
             ])

    assert %{
             "results" => [
               %{"code" => "stale_revision", "group_id" => "destination", "actual_revision" => 2}
             ]
           } =
             submit(conn, [
               Map.merge(transfer("stale-destination", "source", "destination", 0), %{
                 "expected_revision" => 2,
                 "destination_expected_revision" => 1
               })
             ])

    assert %{"results" => [%{"code" => "invalid_amount"}]} =
             submit(conn, [
               Map.merge(transfer("bad-amount", "source", "destination", 0), %{
                 "expected_revision" => 2,
                 "destination_expected_revision" => 2
               })
             ])

    assert %{"results" => [%{"code" => "group_not_found", "group_id" => "missing-source"}]} =
             submit(conn, [transfer("missing-source", "missing-source", "destination", 1)])

    assert %{"results" => [%{"code" => "group_not_found", "group_id" => "missing-destination"}]} =
             submit(conn, [transfer("missing-destination", "source", "missing-destination", 1)])
  end

  test "increments affected groups when reducing and charging back transferred cash", %{
    conn: conn
  } do
    assert %{"results" => [%{}, %{}]} =
             submit(conn, [
               open_operation(%{"group_id" => "source"}),
               open_operation(%{
                 "operation_id" => "open-destination",
                 "group_id" => "destination"
               })
             ])

    assert %{"results" => [%{"revision" => 2}]} =
             submit(conn, [payment("payment-1", "source", 20)])

    assert %{"results" => [%{"source_revision" => 3, "destination_revision" => 2}]} =
             submit(conn, [transfer("transfer-1", "source", "destination", 20)])

    assert %{"results" => [%{"revision" => 4, "outstanding_deposit_cents" => 80}]} =
             submit(conn, [
               %{
                 "operation_id" => "reduce-1",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "payment-1",
                 "amount_cents" => 10,
                 "expected_revision" => 3
               }
             ])

    assert %{"data" => %{"revision" => 3, "cash_paid_cents" => 10}} =
             conn |> get("/api/v1/groups/destination") |> json_response(200)

    assert %{
             "data" => %{
               "held_cents" => 10,
               "held_by_group" => [%{"group_id" => "destination", "amount_cents" => 10}]
             }
           } =
             conn |> get("/api/v1/payments/payment-1") |> json_response(200)

    assert %{"results" => [%{"revision" => 5, "charged_back_cents" => 10}]} =
             submit(conn, [
               %{
                 "operation_id" => "chargeback-1",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "payment-1",
                 "expected_revision" => 4
               }
             ])

    assert %{"data" => %{"revision" => 4, "cash_paid_cents" => 0}} =
             conn |> get("/api/v1/groups/destination") |> json_response(200)
  end
end
