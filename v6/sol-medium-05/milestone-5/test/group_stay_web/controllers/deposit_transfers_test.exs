defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  defp open(id, group, guest \\ "guest", room_count \\ 3) do
    %{
      "operation_id" => id,
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group,
      "guest_id" => guest,
      "property_id" => "ams-canal",
      "arrival_on" => "2027-06-01",
      "departure_on" => "2027-06-02",
      "rate_plan" => "flexible",
      "rooms" =>
        Enum.map(1..room_count, fn position ->
          %{"room_id" => "room-#{position}", "nightly_rate_cents" => 500}
        end)
    }
  end

  defp pay(id, group, amount) do
    %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-02",
      "group_id" => group,
      "amount_cents" => amount
    }
  end

  defp transfer(id, source, destination, amount) do
    %{
      "operation_id" => id,
      "type" => "transfer_deposit",
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount
    }
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group(conn, id), do: get(conn, "/api/v1/groups/#{id}") |> json_response(200)
  defp ledger(conn), do: get(conn, "/api/v1/ledger?on=2027-04-01") |> json_response(200)

  test "mixed funding moves newest-first, keeps provenance, and leaves the ledger unchanged", %{
    conn: conn
  } do
    submit(conn, [
      open("credit-open", "credit-source", "guest", 1),
      pay("credit-cash", "credit-source", 100),
      %{
        "operation_id" => "make-credit",
        "type" => "cancel_group",
        "occurred_on" => "2027-04-01",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      },
      open("source-open", "source"),
      pay("old-cash", "source", 100),
      %{
        "operation_id" => "use-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-04-01",
        "group_id" => "source",
        "amount_cents" => 100
      },
      pay("new-cash", "source", 50),
      open("destination-open", "destination")
    ])

    before_transfer = ledger(conn)
    operation = transfer("transfer", "source", "destination", 120)

    assert [
             %{
               "status" => "applied",
               "source_group_id" => "source",
               "destination_group_id" => "destination",
               "amount_cents" => 120,
               "source_outstanding_deposit_cents" => 170,
               "destination_outstanding_deposit_cents" => 180,
               "source_revision" => 5,
               "destination_revision" => 2
             } = first
           ] = submit(conn, [operation])

    assert ^before_transfer = ledger(conn)

    assert %{
             "data" => %{
               "cash_paid_cents" => 100,
               "credit_paid_cents" => 30,
               "rooms" => [
                 %{"room_id" => "room-1", "cash_paid_cents" => 100},
                 %{"room_id" => "room-2", "credit_paid_cents" => 30},
                 %{"room_id" => "room-3", "cash_paid_cents" => 0}
               ]
             }
           } = group(conn, "source")

    assert %{
             "data" => %{
               "cash_paid_cents" => 50,
               "credit_paid_cents" => 70,
               "rooms" => [
                 %{
                   "room_id" => "room-1",
                   "cash_paid_cents" => 50,
                   "credit_paid_cents" => 50
                 },
                 %{"room_id" => "room-2", "credit_paid_cents" => 20},
                 %{"room_id" => "room-3"}
               ]
             }
           } = group(conn, "destination")

    assert %{
             "data" => %{
               "held_cents" => 50,
               "held_by_group" => [%{"group_id" => "destination", "amount_cents" => 50}]
             }
           } = get(conn, "/api/v1/payments/new-cash") |> json_response(200)

    refute Map.has_key?(
             get(conn, "/api/v1/payments/old-cash") |> json_response(200) |> Map.fetch!("data"),
             "held_by_group"
           )

    # A durable retry returns the original revisions and does not move funding again.
    submit(conn, [pay("later", "source", 1)])
    assert [^first] = submit(conn, [operation])
  end

  test "transferred cash settles at the destination and chargeback revises every changed group",
       %{
         conn: conn
       } do
    submit(conn, [
      open("source-open", "source"),
      pay("pay", "source", 100),
      open("destination-open", "destination"),
      transfer("transfer", "source", "destination", 100),
      %{
        "operation_id" => "cancel-destination",
        "type" => "cancel_group",
        "occurred_on" => "2027-04-01",
        "group_id" => "destination"
      }
    ])

    assert %{"data" => %{"cash_refunded_cents" => 100}} = ledger(conn)

    assert [
             %{
               "status" => "applied",
               "group_id" => "source",
               "charged_back_cents" => 100,
               "outstanding_deposit_cents" => 300,
               "revision" => 4
             }
           ] =
             submit(conn, [
               %{
                 "operation_id" => "chargeback",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "pay",
                 "expected_revision" => 3
               }
             ])

    assert %{"data" => %{"revision" => 4}} = group(conn, "source")

    assert %{"data" => %{"revision" => 4, "status" => "cancelled"}} =
             group(conn, "destination")

    assert %{
             "data" => %{
               "cash_refunded_cents" => 0,
               "cash_charged_back_cents" => 100
             }
           } = ledger(conn)

    assert %{"data" => %{"held_cents" => 0, "held_by_group" => []}} =
             get(conn, "/api/v1/payments/pay") |> json_response(200)
  end

  test "transferred hotel credit returns to its original lot on refundable settlement", %{
    conn: conn
  } do
    submit(conn, [
      open("credit-open", "credit-source", "guest", 1),
      pay("credit-cash", "credit-source", 100),
      %{
        "operation_id" => "make-credit",
        "type" => "cancel_group",
        "occurred_on" => "2027-04-01",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      },
      open("source-open", "source"),
      %{
        "operation_id" => "use-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-04-01",
        "group_id" => "source",
        "amount_cents" => 100
      },
      open("destination-open", "destination"),
      transfer("transfer-credit", "source", "destination", 100),
      %{
        "operation_id" => "cancel-destination",
        "type" => "cancel_group",
        "occurred_on" => "2027-04-02",
        "group_id" => "destination"
      }
    ])

    assert %{
             "data" => %{
               "available_cents" => 110,
               "lots" => [
                 %{
                   "source_operation_id" => "make-credit",
                   "remaining_cents" => 110,
                   "expires_on" => "2028-03-31"
                 }
               ]
             }
           } = get(conn, "/api/v1/guests/guest/credit?on=2027-04-02") |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 110}} = ledger(conn)
  end

  test "reductions follow transferred allocations in reverse allocation order across groups", %{
    conn: conn
  } do
    submit(conn, [
      open("source-open", "source"),
      pay("pay", "source", 150),
      open("destination-open", "destination"),
      transfer("transfer", "source", "destination", 100)
    ])

    assert [
             %{
               "status" => "applied",
               "group_id" => "source",
               "amount_cents" => 120,
               "outstanding_deposit_cents" => 270,
               "revision" => 4
             }
           ] =
             submit(conn, [
               %{
                 "operation_id" => "reduce",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "pay",
                 "amount_cents" => 120,
                 "expected_revision" => 3
               }
             ])

    assert %{"data" => %{"revision" => 4, "cash_paid_cents" => 30}} = group(conn, "source")

    assert %{"data" => %{"revision" => 3, "cash_paid_cents" => 0}} =
             group(conn, "destination")

    assert %{
             "data" => %{
               "held_cents" => 30,
               "held_by_group" => [%{"group_id" => "source", "amount_cents" => 30}]
             }
           } = get(conn, "/api/v1/payments/pay") |> json_response(200)
  end

  test "existence and both revision guards precede transfer domain validation", %{conn: conn} do
    submit(conn, [open("source-open", "source"), open("destination-open", "destination")])

    assert [
             %{"code" => "group_not_found", "group_id" => "missing-source"},
             %{"code" => "group_not_found", "group_id" => "missing-destination"},
             %{
               "code" => "stale_revision",
               "group_id" => "source",
               "expected_revision" => 9,
               "actual_revision" => 1
             },
             %{
               "code" => "stale_revision",
               "group_id" => "destination",
               "expected_revision" => 8,
               "actual_revision" => 1
             }
           ] =
             submit(conn, [
               transfer("missing-source", "missing-source", "missing-destination", -1),
               transfer("missing-destination", "source", "missing-destination", -1),
               transfer("stale-source", "source", "source", -1)
               |> Map.put("expected_revision", 9),
               transfer("stale-destination", "source", "destination", -1)
               |> Map.put("expected_revision", 1)
               |> Map.put("destination_expected_revision", 8)
             ])
  end

  test "transfer rule failures are atomic and inactive errors identify the failing group", %{
    conn: conn
  } do
    submit(conn, [
      open("source-open", "source"),
      pay("pay", "source", 100),
      open("destination-open", "destination"),
      open("other-guest-open", "other-guest", "someone-else"),
      open("small-open", "small", "guest", 1),
      pay("fill-small", "small", 100),
      open("cancelled-open", "cancelled"),
      %{
        "operation_id" => "cancel",
        "type" => "cancel_group",
        "occurred_on" => "2027-04-01",
        "group_id" => "cancelled"
      }
    ])

    assert [
             %{"code" => "invalid_transfer"},
             %{"code" => "invalid_transfer"},
             %{"code" => "invalid_amount"},
             %{"code" => "transfer_exceeds_held_funding"},
             %{"code" => "transfer_exceeds_outstanding"},
             %{"code" => "group_not_active", "group_id" => "cancelled"},
             %{"code" => "group_not_active", "group_id" => "cancelled"}
           ] =
             submit(conn, [
               transfer("same", "source", "source", 1),
               transfer("guest-mismatch", "source", "other-guest", 1),
               transfer("zero", "source", "destination", 0),
               transfer("too-much-held", "source", "destination", 101),
               transfer("too-much-outstanding", "source", "small", 1),
               transfer("inactive-source", "cancelled", "destination", 1),
               transfer("inactive-destination", "source", "cancelled", 1)
             ])

    assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 100}} = group(conn, "source")

    assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} =
             group(conn, "destination")
  end
end
