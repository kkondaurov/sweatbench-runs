defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  test "transfers newest funding first, fills the destination in order, and retries exactly", %{
    conn: conn
  } do
    transfer = transfer("transfer-a", "source-a", "destination-a", 700, 3, 1)

    response =
      post_ops(conn, [
        open("open-source-a", "source-a", "guest-a", [5_000, 5_000]),
        cash("pay-a1", "source-a", 1_000),
        cash("pay-a2", "source-a", 500),
        open("open-destination-a", "destination-a", "guest-a", [5_000, 5_000]),
        transfer
      ])

    assert List.last(response["results"]) == %{
             "operation_id" => "transfer-a",
             "status" => "applied",
             "source_group_id" => "source-a",
             "destination_group_id" => "destination-a",
             "amount_cents" => 700,
             "source_outstanding_deposit_cents" => 1_200,
             "destination_outstanding_deposit_cents" => 1_300,
             "source_revision" => 4,
             "destination_revision" => 2
           }

    assert Enum.map(group(conn, "source-a")["rooms"], & &1["cash_paid_cents"]) == [800, 0]

    assert Enum.map(group(conn, "destination-a")["rooms"], & &1["cash_paid_cents"]) ==
             [700, 0]

    assert payment(conn, "pay-a1")["held_by_group"] == [
             %{"group_id" => "destination-a", "amount_cents" => 200},
             %{"group_id" => "source-a", "amount_cents" => 800}
           ]

    assert payment(conn, "pay-a2")["held_by_group"] == [
             %{"group_id" => "destination-a", "amount_cents" => 500}
           ]

    assert ledger(conn)["cash_held_cents"] == 1_500

    post_ops(conn, [cash("pay-after-transfer", "destination-a", 100)])
    assert post_ops(conn, [transfer]) == %{"results" => [List.last(response["results"])]}
    assert group(conn, "source-a")["revision"] == 4
    assert group(conn, "destination-a")["revision"] == 3
    assert ledger(conn)["cash_held_cents"] == 1_600
  end

  test "transfer validation follows existence and revision precedence without partial changes", %{
    conn: conn
  } do
    post_ops(conn, [
      open("open-source-v", "source-v", "guest-v", [10_000]),
      open("open-destination-v", "destination-v", "guest-v", [10_000]),
      cash("pay-v", "source-v", 1_000)
    ])

    assert_rejection(conn, transfer("missing-source", "absent", "also-absent", -1), %{
      "code" => "group_not_found",
      "group_id" => "absent"
    })

    assert_rejection(conn, transfer("missing-destination", "source-v", "absent", -1), %{
      "code" => "group_not_found",
      "group_id" => "absent"
    })

    assert_rejection(conn, transfer("stale-source", "source-v", "destination-v", -1, 1, 0), %{
      "code" => "stale_revision",
      "group_id" => "source-v",
      "expected_revision" => 1,
      "actual_revision" => 2
    })

    assert_rejection(
      conn,
      transfer("stale-destination", "source-v", "destination-v", -1, 2, 0),
      %{
        "code" => "stale_revision",
        "group_id" => "destination-v",
        "expected_revision" => 0,
        "actual_revision" => 1
      }
    )

    assert_rejection(conn, transfer("same-group", "source-v", "source-v", 100), %{
      "code" => "invalid_transfer"
    })

    post_ops(conn, [open("open-other-guest", "other-guest", "someone-else", [10_000])])

    assert_rejection(conn, transfer("different-guests", "source-v", "other-guest", 100), %{
      "code" => "invalid_transfer"
    })

    assert_rejection(conn, transfer("bad-amount", "source-v", "destination-v", 0), %{
      "code" => "invalid_amount"
    })

    assert_rejection(conn, transfer("too-much-held", "source-v", "destination-v", 1_001), %{
      "code" => "transfer_exceeds_held_funding"
    })

    post_ops(conn, [cash("fill-destination", "destination-v", 1_900)])

    assert_rejection(conn, transfer("too-much-destination", "source-v", "destination-v", 101), %{
      "code" => "transfer_exceeds_outstanding"
    })

    assert group(conn, "source-v")["cash_paid_cents"] == 1_000
    assert group(conn, "source-v")["revision"] == 2
    assert group(conn, "destination-v")["cash_paid_cents"] == 1_900
    assert group(conn, "destination-v")["revision"] == 2

    post_ops(conn, [cancel("cancel-destination-v", "destination-v")])

    assert_rejection(conn, transfer("inactive-destination", "source-v", "destination-v", 100), %{
      "code" => "group_not_active",
      "group_id" => "destination-v"
    })

    post_ops(conn, [cancel("cancel-source-v", "source-v")])

    assert_rejection(conn, transfer("inactive-source", "source-v", "destination-v", 100), %{
      "code" => "group_not_active",
      "group_id" => "source-v"
    })
  end

  test "transferred hotel credit retains its lot and restores under the destination policy", %{
    conn: conn
  } do
    post_ops(conn, [
      open("open-credit-origin", "credit-origin", "guest-credit", [5_000]),
      cash("pay-credit-origin", "credit-origin", 1_000),
      cancel("issue-credit", "credit-origin", "2026-10-10", "hotel_credit"),
      open("open-credit-source", "credit-source", "guest-credit", [5_000]),
      cash("pay-credit-source", "credit-source", 200),
      credit("apply-credit", "credit-source", 600),
      open("open-credit-destination", "credit-destination", "guest-credit", [5_000]),
      transfer("transfer-credit", "credit-source", "credit-destination", 400, 3, 1)
    ])

    assert group(conn, "credit-source")["cash_paid_cents"] == 200
    assert group(conn, "credit-source")["credit_paid_cents"] == 200
    assert group(conn, "credit-destination")["credit_paid_cents"] == 400
    refute Map.has_key?(payment(conn, "pay-credit-source"), "held_by_group")
    assert guest_credit(conn, "guest-credit")["available_cents"] == 500
    assert ledger(conn)["credit_liability_cents"] == 1_100

    assert %{"results" => [%{"refunded_cents" => 0, "credit_issued_cents" => 0}]} =
             post_ops(conn, [cancel("cancel-credit-destination", "credit-destination")])

    assert guest_credit(conn, "guest-credit")["available_cents"] == 900
    assert ledger(conn)["credit_liability_cents"] == 1_100
  end

  test "reductions follow transferred payment allocations and revise every changed group", %{
    conn: conn
  } do
    post_ops(conn, [
      open("open-source-r", "source-r", "guest-r", [10_000]),
      cash("pay-r", "source-r", 1_000),
      open("open-destination-r", "destination-r", "guest-r", [10_000]),
      transfer("transfer-r", "source-r", "destination-r", 400, 2, 1)
    ])

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "amount_cents" => 500,
                 "group_id" => "source-r",
                 "revision" => 4
               }
             ]
           } =
             post_ops(conn, [
               %{
                 "operation_id" => "reduce-r",
                 "type" => "reduce_cash_payment",
                 "occurred_on" => "2026-10-07",
                 "payment_operation_id" => "pay-r",
                 "amount_cents" => 500,
                 "expected_revision" => 3
               }
             ])

    assert group(conn, "source-r")["cash_paid_cents"] == 500
    assert group(conn, "destination-r")["cash_paid_cents"] == 0
    assert group(conn, "destination-r")["revision"] == 3

    statement = payment(conn, "pay-r")
    assert statement["held_cents"] == 500
    assert statement["reduced_cents"] == 500
    assert statement["held_by_group"] == [%{"group_id" => "source-r", "amount_cents" => 500}]
  end

  test "destination settlement governs transferred cash and chargeback revises both groups", %{
    conn: conn
  } do
    post_ops(conn, [
      open("open-source-c", "source-c", "guest-c", [5_000]),
      cash("pay-c", "source-c", 1_000),
      open("open-destination-c", "destination-c", "guest-c", [1_000], "advance_purchase"),
      transfer("transfer-c", "source-c", "destination-c", 1_000, 2, 1),
      cancel("cancel-destination-c", "destination-c")
    ])

    statement = payment(conn, "pay-c")
    assert statement["retained_cents"] == 1_000
    assert statement["held_cents"] == 0
    assert statement["held_by_group"] == []

    assert %{"results" => [%{"charged_back_cents" => 1_000, "revision" => 4}]} =
             post_ops(conn, [
               %{
                 "operation_id" => "charge-c",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-12",
                 "payment_operation_id" => "pay-c",
                 "expected_revision" => 3
               }
             ])

    assert group(conn, "source-c")["revision"] == 4
    assert group(conn, "destination-c")["revision"] == 4
    assert payment(conn, "pay-c")["charged_back_cents"] == 1_000
    assert ledger(conn)["cash_retained_cents"] == 0
    assert ledger(conn)["cash_charged_back_cents"] == 1_000
  end

  defp assert_rejection(conn, operation, expected) do
    assert %{"results" => [result]} = post_ops(conn, [operation])
    assert Map.take(result, Map.keys(expected)) == expected
  end

  defp open(operation_id, group_id, guest_id, rates, rate_plan \\ "flexible") do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => rate_plan,
      "rooms" =>
        rates
        |> Enum.with_index(1)
        |> Enum.map(fn {rate, index} ->
          %{"room_id" => "room-#{index}", "nightly_rate_cents" => rate}
        end)
    }
  end

  defp cash(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-05",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp credit(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-10-11",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancel(operation_id, group_id, occurred_on \\ "2026-10-11", refund_method \\ nil) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
    |> then(fn operation ->
      if refund_method, do: Map.put(operation, "refund_method", refund_method), else: operation
    end)
  end

  defp transfer(
         operation_id,
         source_id,
         destination_id,
         amount,
         source_revision \\ nil,
         destination_revision \\ nil
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => "2026-10-06",
      "source_group_id" => source_id,
      "destination_group_id" => destination_id,
      "amount_cents" => amount
    }
    |> maybe_put("expected_revision", source_revision)
    |> maybe_put("destination_expected_revision", destination_revision)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp post_ops(conn, operations) do
    conn
    |> recycle()
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp group(conn, group_id) do
    get(recycle(conn), "/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp payment(conn, operation_id) do
    get(recycle(conn), "/api/v1/payments/#{operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp guest_credit(conn, guest_id) do
    get(recycle(conn), "/api/v1/guests/#{guest_id}/credit?on=2026-10-15")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn) do
    get(recycle(conn), "/api/v1/ledger?on=2026-10-15")
    |> json_response(200)
    |> Map.fetch!("data")
  end
end
