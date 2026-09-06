defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  defp operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-source",
        "type" => "open_group",
        "occurred_on" => "2027-02-01",
        "group_id" => "source",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-04-15",
        "departure_on" => "2027-04-16",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  test "moves cash and credit allocations in reverse source order and preserves provenance", %{
    conn: conn
  } do
    post_batch(conn, [
      operation(%{
        "operation_id" => "open-credit-source",
        "group_id" => "credit-source"
      }),
      operation(%{
        "operation_id" => "pay-credit-source",
        "type" => "record_cash_payment",
        "group_id" => "credit-source",
        "amount_cents" => 1_000
      }),
      operation(%{
        "operation_id" => "cancel-credit-source",
        "type" => "cancel_group",
        "group_id" => "credit-source",
        "occurred_on" => "2027-02-01",
        "refund_method" => "hotel_credit"
      }),
      operation(%{
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 10_000}
        ]
      }),
      operation(%{
        "operation_id" => "open-destination",
        "type" => "open_group",
        "group_id" => "destination",
        "rooms" => [
          %{"room_id" => "destination-a", "nightly_rate_cents" => 5_000},
          %{"room_id" => "destination-b", "nightly_rate_cents" => 5_000}
        ]
      }),
      operation(%{
        "operation_id" => "pay-source",
        "type" => "record_cash_payment",
        "amount_cents" => 1_500
      }),
      operation(%{
        "operation_id" => "apply-source-credit",
        "type" => "apply_hotel_credit",
        "amount_cents" => 500,
        "occurred_on" => "2027-02-02"
      })
    ])

    assert %{
             "results" => [
               %{
                 "amount_cents" => 1_800,
                 "source_group_id" => "source",
                 "destination_group_id" => "destination",
                 "source_revision" => 4,
                 "destination_revision" => 2,
                 "source_outstanding_deposit_cents" => 3_800,
                 "destination_outstanding_deposit_cents" => 200
               }
             ]
           } =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "transfer-17",
                 "type" => "transfer_deposit",
                 "source_group_id" => "source",
                 "destination_group_id" => "destination",
                 "amount_cents" => 1_800,
                 "expected_revision" => 3,
                 "destination_expected_revision" => 1
               })
             ])

    assert %{
             "results" => [
               %{
                 "source_revision" => 4,
                 "destination_revision" => 2
               }
             ]
           } =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "transfer-17",
                 "type" => "transfer_deposit",
                 "source_group_id" => "source",
                 "destination_group_id" => "destination",
                 "amount_cents" => 1_800,
                 "expected_revision" => 3,
                 "destination_expected_revision" => 1
               })
             ])

    assert %{
             "data" => %{
               "cash_paid_cents" => 200,
               "credit_paid_cents" => 0,
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 200},
                 %{"room_id" => "room-b", "cash_paid_cents" => 0}
               ]
             }
           } = get(conn, "/api/v1/groups/source") |> json_response(200)

    assert %{
             "data" => %{
               "cash_paid_cents" => 1_300,
               "credit_paid_cents" => 500,
               "rooms" => [
                 %{
                   "room_id" => "destination-a",
                   "cash_paid_cents" => 500,
                   "credit_paid_cents" => 500
                 },
                 %{"room_id" => "destination-b", "cash_paid_cents" => 800}
               ]
             }
           } = get(conn, "/api/v1/groups/destination") |> json_response(200)

    assert %{
             "data" => %{
               "held_cents" => 1_500,
               "held_by_group" => [
                 %{"group_id" => "destination", "amount_cents" => 1_300},
                 %{"group_id" => "source", "amount_cents" => 200}
               ]
             }
           } = get(conn, "/api/v1/payments/pay-source") |> json_response(200)
  end

  test "checks both revisions before transfer validation and identifies missing or inactive groups",
       %{
         conn: conn
       } do
    post_batch(conn, [
      operation(),
      operation(%{
        "operation_id" => "open-destination",
        "type" => "open_group",
        "group_id" => "destination"
      })
    ])

    assert %{
             "results" => [
               %{
                 "code" => "stale_revision",
                 "group_id" => "destination",
                 "expected_revision" => 9,
                 "actual_revision" => 1
               }
             ]
           } =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "stale-destination",
                 "type" => "transfer_deposit",
                 "source_group_id" => "source",
                 "destination_group_id" => "destination",
                 "amount_cents" => 1,
                 "expected_revision" => 1,
                 "destination_expected_revision" => 9
               })
             ])

    assert %{"results" => [%{"code" => "group_not_found", "group_id" => "missing-source"}]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "missing-source",
                 "type" => "transfer_deposit",
                 "source_group_id" => "missing-source",
                 "destination_group_id" => "destination",
                 "amount_cents" => 1
               })
             ])

    assert %{"results" => [%{"code" => "group_not_found", "group_id" => "missing-destination"}]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "missing-destination",
                 "type" => "transfer_deposit",
                 "source_group_id" => "source",
                 "destination_group_id" => "missing-destination",
                 "amount_cents" => 1
               })
             ])

    assert %{"results" => [%{"code" => "invalid_transfer"}]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "same-group",
                 "type" => "transfer_deposit",
                 "source_group_id" => "source",
                 "destination_group_id" => "source",
                 "amount_cents" => 1
               })
             ])

    post_batch(conn, [
      operation(%{
        "operation_id" => "cancel-destination",
        "type" => "cancel_group",
        "group_id" => "destination",
        "occurred_on" => "2027-02-01"
      })
    ])

    assert %{"results" => [%{"code" => "group_not_active", "group_id" => "destination"}]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "inactive-destination",
                 "type" => "transfer_deposit",
                 "source_group_id" => "source",
                 "destination_group_id" => "destination",
                 "amount_cents" => 1,
                 "expected_revision" => 1,
                 "destination_expected_revision" => 2
               })
             ])
  end

  test "reductions follow transferred cash and increment every changed group", %{conn: conn} do
    post_batch(conn, [
      operation(),
      operation(%{
        "operation_id" => "open-destination",
        "type" => "open_group",
        "group_id" => "destination"
      }),
      operation(%{
        "operation_id" => "pay-source",
        "type" => "record_cash_payment",
        "amount_cents" => 2_000
      }),
      operation(%{
        "operation_id" => "transfer",
        "type" => "transfer_deposit",
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 1_000,
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      })
    ])

    assert %{"results" => [%{"revision" => 4, "amount_cents" => 1_500}]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "reduce",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "pay-source",
                 "amount_cents" => 1_500,
                 "expected_revision" => 3
               })
             ])

    assert %{"data" => %{"revision" => 4, "outstanding_deposit_cents" => 1_500}} =
             get(conn, "/api/v1/groups/source") |> json_response(200)

    assert %{"data" => %{"revision" => 3, "outstanding_deposit_cents" => 2_000}} =
             get(conn, "/api/v1/groups/destination") |> json_response(200)

    assert %{
             "data" => %{
               "held_cents" => 500,
               "held_by_group" => [%{"group_id" => "source", "amount_cents" => 500}],
               "reduced_cents" => 1_500
             }
           } = get(conn, "/api/v1/payments/pay-source") |> json_response(200)
  end

  test "chargeback reclassifies a transferred refund without changing the destination revision",
       %{
         conn: conn
       } do
    post_batch(conn, [
      operation(),
      operation(%{
        "operation_id" => "open-destination",
        "type" => "open_group",
        "group_id" => "destination"
      }),
      operation(%{
        "operation_id" => "pay-source",
        "type" => "record_cash_payment",
        "amount_cents" => 2_000
      }),
      operation(%{
        "operation_id" => "transfer",
        "type" => "transfer_deposit",
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 2_000,
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      }),
      operation(%{
        "operation_id" => "cancel-destination",
        "type" => "cancel_group",
        "group_id" => "destination",
        "occurred_on" => "2027-02-01"
      })
    ])

    assert %{"results" => [%{"charged_back_cents" => 2_000, "revision" => 4}]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "chargeback",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "pay-source",
                 "expected_revision" => 3
               })
             ])

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_charged_back_cents" => 2_000
             }
           } = get(conn, "/api/v1/ledger") |> json_response(200)

    assert %{
             "data" => %{
               "held_cents" => 0,
               "refunded_cents" => 0,
               "charged_back_cents" => 2_000
             }
           } = get(conn, "/api/v1/payments/pay-source") |> json_response(200)

    assert %{"data" => %{"revision" => 3, "status" => "cancelled"}} =
             get(conn, "/api/v1/groups/destination") |> json_response(200)
  end
end
