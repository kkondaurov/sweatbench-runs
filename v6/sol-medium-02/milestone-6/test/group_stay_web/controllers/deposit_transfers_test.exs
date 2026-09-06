defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  defp open(id, group, guest \\ "guest", overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => "open_group",
        "occurred_on" => "2026-10-01",
        "group_id" => group,
        "guest_id" => guest,
        "property_id" => "ams",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rate_plan" => "advance_purchase",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 300}]
      },
      overrides
    )
  end

  defp pay(id, group, amount) do
    %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-02",
      "group_id" => group,
      "amount_cents" => amount
    }
  end

  defp transfer(id, source, destination, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-03",
        "source_group_id" => source,
        "destination_group_id" => destination,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group(conn, id),
    do: conn |> get("/api/v1/groups/#{id}") |> json_response(200) |> Map.fetch!("data")

  test "moves newest allocations first, exposes payment locations, and reduces across groups", %{
    conn: conn
  } do
    destination_rooms = [
      %{"room_id" => "d1", "nightly_rate_cents" => 120},
      %{"room_id" => "d2", "nightly_rate_cents" => 180}
    ]

    submit(conn, [
      open("source-open", "source"),
      open("destination-open", "destination", "guest", %{"rooms" => destination_rooms}),
      pay("p1", "source", 100),
      pay("p2", "source", 100)
    ])

    [moved] =
      submit(conn, [
        transfer("move", "source", "destination", 150, %{
          "expected_revision" => 3,
          "destination_expected_revision" => 1
        })
      ])

    assert moved == %{
             "operation_id" => "move",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 150,
             "source_outstanding_deposit_cents" => 250,
             "destination_outstanding_deposit_cents" => 150,
             "source_revision" => 4,
             "destination_revision" => 2
           }

    assert Enum.map(group(conn, "destination")["rooms"], & &1["cash_paid_cents"]) == [120, 30]

    p1 = conn |> get("/api/v1/payments/p1") |> json_response(200) |> Map.fetch!("data")
    p2 = conn |> get("/api/v1/payments/p2") |> json_response(200) |> Map.fetch!("data")

    assert p1["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 50},
             %{"group_id" => "source", "amount_cents" => 50}
           ]

    assert p2["held_by_group"] == [%{"group_id" => "destination", "amount_cents" => 100}]

    [reduced] =
      submit(conn, [
        %{
          "operation_id" => "reduce",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-04",
          "payment_operation_id" => "p2",
          "amount_cents" => 60,
          "expected_revision" => 4
        }
      ])

    assert reduced["revision"] == 5
    assert group(conn, "destination")["revision"] == 3
    assert group(conn, "destination")["cash_paid_cents"] == 90
    assert group(conn, "source")["cash_paid_cents"] == 50

    [spanning] =
      submit(conn, [
        %{
          "operation_id" => "spanning-reduce",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-04",
          "payment_operation_id" => "p1",
          "amount_cents" => 60,
          "expected_revision" => 5
        }
      ])

    assert spanning["revision"] == 6
    assert group(conn, "destination")["revision"] == 4
    assert group(conn, "destination")["cash_paid_cents"] == 40
    assert group(conn, "source")["cash_paid_cents"] == 40
  end

  test "mixed funding preserves provenance and transfer itself leaves ledger totals unchanged", %{
    conn: conn
  } do
    flexible = %{
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 1000}]
    }

    submit(conn, [
      open("seed-open", "seed", "guest", flexible),
      pay("seed-pay", "seed", 100),
      %{
        "operation_id" => "make-credit",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "seed",
        "refund_method" => "hotel_credit"
      },
      open("source-open", "source", "guest", flexible),
      open("destination-open", "destination", "guest", flexible),
      pay("cash", "source", 100),
      %{
        "operation_id" => "credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-04",
        "group_id" => "source",
        "amount_cents" => 100
      }
    ])

    before = conn |> get("/api/v1/ledger?on=2026-10-04") |> json_response(200)
    [first] = submit(conn, [transfer("move", "source", "destination", 150)])
    assert first["status"] == "applied"
    assert conn |> get("/api/v1/ledger?on=2026-10-04") |> json_response(200) == before

    destination = group(conn, "destination")
    assert {destination["cash_paid_cents"], destination["credit_paid_cents"]} == {50, 100}

    assert {group(conn, "source")["cash_paid_cents"], group(conn, "source")["credit_paid_cents"]} ==
             {50, 0}

    # Durable replay returns the stored revisions and does not move another 150 cents.
    assert submit(conn, [transfer("move", "source", "destination", 150)]) == [first]
    assert group(conn, "destination")["deposit_paid_cents"] == 150

    [cancelled] =
      submit(conn, [
        %{
          "operation_id" => "destination-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-05",
          "group_id" => "destination",
          "refund_method" => "hotel_credit"
        }
      ])

    assert cancelled["credit_issued_cents"] == 55

    credit =
      conn
      |> get("/api/v1/guests/guest/credit?on=2026-10-05")
      |> json_response(200)
      |> Map.fetch!("data")

    assert credit["available_cents"] == 165
  end

  test "validates existence and both revisions before transfer rules", %{conn: conn} do
    submit(conn, [
      open("a-open", "a"),
      open("b-open", "b"),
      open("other-open", "other", "other-guest"),
      open("small-open", "small", "guest", %{
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10}]
      }),
      pay("pay", "a", 100)
    ])

    [
      missing_source,
      missing_destination,
      stale_source,
      stale_destination,
      same,
      other_guest,
      invalid_amount,
      too_much_funding,
      too_much_outstanding
    ] =
      submit(conn, [
        transfer("missing-source", "missing", "also-missing", 1),
        transfer("missing-destination", "a", "missing", 1),
        transfer("stale-source", "a", "b", -1, %{"expected_revision" => 1}),
        transfer("stale-destination", "a", "b", -1, %{
          "expected_revision" => 2,
          "destination_expected_revision" => 9
        }),
        transfer("same", "a", "a", 1),
        transfer("other-guest", "a", "other", 1),
        transfer("invalid-amount", "a", "b", 0),
        transfer("too-much-funding", "a", "b", 101),
        transfer("too-much-outstanding", "a", "small", 11)
      ])

    assert {missing_source["code"], missing_source["group_id"]} == {"group_not_found", "missing"}

    assert {missing_destination["code"], missing_destination["group_id"]} ==
             {"group_not_found", "missing"}

    assert stale_source["code"] == "stale_revision"
    assert stale_source["group_id"] == "a"
    assert stale_destination["code"] == "stale_revision"
    assert stale_destination["group_id"] == "b"
    assert same["code"] == "invalid_transfer"
    assert other_guest["code"] == "invalid_transfer"
    assert invalid_amount["code"] == "invalid_amount"
    assert too_much_funding["code"] == "transfer_exceeds_held_funding"
    assert too_much_outstanding["code"] == "transfer_exceeds_outstanding"
  end

  test "chargeback reclassifies transferred cash settled by the destination", %{conn: conn} do
    submit(conn, [
      open("source-open", "source"),
      open("destination-open", "destination"),
      pay("pay", "source", 100),
      transfer("move", "source", "destination", 100),
      %{
        "operation_id" => "cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "destination"
      }
    ])

    [charged] =
      submit(conn, [
        %{
          "operation_id" => "chargeback",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-10-05",
          "payment_operation_id" => "pay",
          "expected_revision" => 3
        }
      ])

    assert charged["revision"] == 4
    assert group(conn, "destination")["revision"] == 4

    statement = conn |> get("/api/v1/payments/pay") |> json_response(200) |> Map.fetch!("data")
    assert statement["held_by_group"] == []
    assert statement["retained_cents"] == 0
    assert statement["charged_back_cents"] == 100

    ledger = conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
    assert ledger["cash_retained_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 100
  end
end
