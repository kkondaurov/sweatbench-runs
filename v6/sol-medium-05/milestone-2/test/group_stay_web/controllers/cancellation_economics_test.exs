defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  defp open(operation_id, group_id, guest_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => "2026-12-01",
        "group_id" => group_id,
        "guest_id" => guest_id,
        "property_id" => "ams-canal",
        "arrival_on" => "2027-03-10",
        "departure_on" => "2027-03-11",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-1", "nightly_rate_cents" => 500}]
      },
      overrides
    )
  end

  defp payment(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-12-02",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancellation(operation_id, group_id, occurred_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id
      },
      overrides
    )
  end

  defp credit_payment(operation_id, group_id, occurred_on, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "apply_hotel_credit",
        "occurred_on" => occurred_on,
        "group_id" => group_id,
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

  test "policy is fixed at booking cutoff and refundable date follows reschedules", %{conn: conn} do
    assert [_, _, _] =
             submit(conn, [
               open("old", "old-flex", "guest", %{"occurred_on" => "2026-12-31"}),
               open("new", "new-flex", "guest", %{"occurred_on" => "2027-01-01"}),
               open("advance", "advance", "guest", %{
                 "occurred_on" => "2027-01-01",
                 "rate_plan" => "advance_purchase"
               })
             ])

    assert %{
             "data" => %{
               "policy_version" => "flex-14",
               "refundable_until" => "2027-02-24",
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
             }
           } = get(conn, "/api/v1/groups/old-flex") |> json_response(200)

    assert %{"data" => %{"policy_version" => "flex-30", "refundable_until" => "2027-02-08"}} =
             get(conn, "/api/v1/groups/new-flex") |> json_response(200)

    assert %{
             "data" => %{
               "policy_version" => "advance-nonrefundable",
               "refundable_until" => nil
             }
           } = get(conn, "/api/v1/groups/advance") |> json_response(200)

    assert [
             %{
               "status" => "applied",
               "policy_version" => "flex-14",
               "refundable_until" => "2027-03-18",
               "new_departure_on" => "2027-04-02",
               "revision" => 2
             }
           ] =
             submit(conn, [
               %{
                 "operation_id" => "move",
                 "type" => "reschedule_group",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "old-flex",
                 "new_arrival_on" => "2027-04-01"
               }
             ])
  end

  test "refundable cash can become bonus credit with inclusive expiry", %{conn: conn} do
    assert [_, _, %{"credit_issued_cents" => 6, "refunded_cents" => 0, "retained_cents" => 0}] =
             submit(conn, [
               open("open", "source", "guest", %{
                 "occurred_on" => "2027-01-01",
                 "rooms" => [%{"room_id" => "tiny", "nightly_rate_cents" => 25}]
               }),
               payment("pay", "source", 5),
               cancellation("cancel-credit", "source", "2027-02-08", %{
                 "refund_method" => "hotel_credit"
               })
             ])

    assert %{
             "data" => %{
               "available_cents" => 6,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-credit",
                   "remaining_cents" => 6,
                   "expires_on" => "2028-02-08"
                 }
               ]
             }
           } = get(conn, "/api/v1/guests/guest/credit?on=2028-02-08") |> json_response(200)

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             get(conn, "/api/v1/guests/guest/credit?on=2028-02-09") |> json_response(200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5,
               "credit_liability_cents" => 6
             }
           } = get(conn, "/api/v1/ledger?on=2028-02-08") |> json_response(200)
  end

  test "hotel credit cancellation is unavailable when nonrefundable and revision wins first", %{
    conn: conn
  } do
    submit(conn, [
      open("open", "late", "guest", %{"occurred_on" => "2027-01-01"}),
      payment("pay", "late", 20)
    ])

    assert [
             %{"code" => "stale_revision", "actual_revision" => 2},
             %{"code" => "refund_method_not_available"}
           ] =
             submit(conn, [
               cancellation("stale", "late", "2027-02-09", %{
                 "refund_method" => "hotel_credit",
                 "expected_revision" => 1
               }),
               cancellation("unavailable", "late", "2027-02-09", %{
                 "refund_method" => "hotel_credit",
                 "expected_revision" => 2
               })
             ])

    assert %{"data" => %{"status" => "active", "revision" => 2}} =
             get(conn, "/api/v1/groups/late") |> json_response(200)
  end

  test "credit consumes earliest lot and source id, then refundable cancellation restores it", %{
    conn: conn
  } do
    assert [_, _, _, _, _, _, _, %{"amount_cents" => 80, "revision" => 2}] =
             submit(conn, [
               open("source-z", "source-z", "guest"),
               payment("pay-z", "source-z", 50),
               cancellation("z-lot", "source-z", "2027-02-01", %{
                 "refund_method" => "hotel_credit"
               }),
               open("source-a", "source-a", "guest"),
               payment("pay-a", "source-a", 50),
               cancellation("a-lot", "source-a", "2027-02-01", %{
                 "refund_method" => "hotel_credit"
               }),
               open("target", "target", "guest", %{
                 "occurred_on" => "2027-01-01",
                 "arrival_on" => "2027-05-01",
                 "departure_on" => "2027-05-02"
               }),
               credit_payment("use", "target", "2027-02-02", 80, %{"expected_revision" => 1})
             ])

    assert %{
             "data" => %{
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 80,
               "deposit_paid_cents" => 80,
               "outstanding_deposit_cents" => 20
             }
           } = get(conn, "/api/v1/groups/target") |> json_response(200)

    assert %{
             "data" => %{
               "available_cents" => 30,
               "lots" => [%{"source_operation_id" => "z-lot", "remaining_cents" => 30}]
             }
           } = get(conn, "/api/v1/guests/guest/credit?on=2027-02-03") |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 110, "cash_held_cents" => 0}} =
             get(conn, "/api/v1/ledger?on=2027-02-03") |> json_response(200)

    assert [%{"credit_issued_cents" => 0, "refunded_cents" => 0, "revision" => 3}] =
             submit(conn, [cancellation("cancel-target", "target", "2027-03-01")])

    assert %{
             "data" => %{
               "available_cents" => 110,
               "lots" => [
                 %{"source_operation_id" => "a-lot", "remaining_cents" => 55},
                 %{"source_operation_id" => "z-lot", "remaining_cents" => 55}
               ]
             }
           } = get(conn, "/api/v1/guests/guest/credit?on=2027-03-01") |> json_response(200)
  end

  test "mixed refundable funding settles cash once and restores credit without another bonus", %{
    conn: conn
  } do
    submit(conn, [
      open("source", "source", "guest"),
      payment("source-pay", "source", 50),
      cancellation("original-lot", "source", "2027-02-01", %{
        "refund_method" => "hotel_credit"
      }),
      open("target", "target", "guest", %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-05-01",
        "departure_on" => "2027-05-02"
      }),
      payment("target-cash", "target", 20),
      credit_payment("target-credit", "target", "2027-02-02", 50)
    ])

    assert [
             %{
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 22,
               "revision" => 4
             }
           ] =
             submit(conn, [
               cancellation("target-lot", "target", "2027-03-01", %{
                 "refund_method" => "hotel_credit"
               })
             ])

    assert %{
             "data" => %{
               "available_cents" => 77,
               "lots" => [
                 %{"source_operation_id" => "original-lot", "remaining_cents" => 55},
                 %{"source_operation_id" => "target-lot", "remaining_cents" => 22}
               ]
             }
           } = get(conn, "/api/v1/guests/guest/credit?on=2027-03-01") |> json_response(200)

    assert %{
             "data" => %{
               "cash_converted_to_credit_cents" => 70,
               "credit_liability_cents" => 77
             }
           } = get(conn, "/api/v1/ledger?on=2027-03-01") |> json_response(200)
  end

  test "applied credit pauses expiry but expired restoration and nonrefundable use reduce liability",
       %{conn: conn} do
    submit(conn, [
      open("source", "source", "guest", %{
        "occurred_on" => "2026-01-01",
        "arrival_on" => "2026-03-10",
        "departure_on" => "2026-03-11"
      }),
      payment("pay", "source", 100),
      cancellation("lot", "source", "2026-02-01", %{"refund_method" => "hotel_credit"}),
      open("target", "target", "guest", %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-04-01",
        "departure_on" => "2027-04-02"
      }),
      credit_payment("use", "target", "2027-01-31", 100)
    ])

    assert %{"data" => %{"available_cents" => 0}} =
             get(conn, "/api/v1/guests/guest/credit?on=2027-02-02") |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 100}} =
             get(conn, "/api/v1/ledger?on=2027-02-02") |> json_response(200)

    submit(conn, [cancellation("cancel-target", "target", "2027-02-02")])

    assert %{"data" => %{"credit_liability_cents" => 0}} =
             get(conn, "/api/v1/ledger?on=2027-02-02") |> json_response(200)

    submit(conn, [open("expired-target", "expired-target", "guest")])

    assert [%{"code" => "insufficient_credit"}] =
             submit(conn, [credit_payment("expired-use", "expired-target", "2027-02-02", 1)])

    assert [
             %{"status" => "applied"},
             %{"status" => "applied"},
             %{"status" => "applied"},
             %{"status" => "applied"}
           ] =
             submit(conn, [
               open("source-2", "source-2", "guest-2", %{
                 "occurred_on" => "2026-01-01",
                 "arrival_on" => "2026-03-10",
                 "departure_on" => "2026-03-11"
               }),
               payment("pay-2", "source-2", 100),
               cancellation("lot-2", "source-2", "2026-02-01", %{
                 "refund_method" => "hotel_credit"
               }),
               open("advance", "advance", "guest-2", %{
                 "occurred_on" => "2026-03-01",
                 "rate_plan" => "advance_purchase",
                 "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 100}]
               })
             ])

    assert %{"data" => %{"credit_liability_cents" => 120}} =
             get(conn, "/api/v1/ledger?on=2026-03-03") |> json_response(200)

    assert [%{"status" => "applied"}, %{"credit_issued_cents" => 0}] =
             submit(conn, [
               credit_payment("use-2", "advance", "2026-03-02", 100),
               cancellation("cancel-advance", "advance", "2026-03-03")
             ])

    assert %{"data" => %{"credit_liability_cents" => 20}} =
             get(conn, "/api/v1/ledger?on=2026-03-03") |> json_response(200)
  end

  test "credit payment validations roll back and reporting dates reject malformed input", %{
    conn: conn
  } do
    submit(conn, [open("open", "group", "guest")])

    assert [
             %{"code" => "stale_revision"},
             %{"code" => "invalid_amount"},
             %{"code" => "payment_exceeds_outstanding"},
             %{"code" => "insufficient_credit"}
           ] =
             submit(conn, [
               credit_payment("stale", "group", "bad", -1, %{"expected_revision" => 9}),
               credit_payment("zero", "group", "2027-01-01", 0),
               credit_payment("too-much", "group", "2027-01-01", 101),
               credit_payment("none", "group", "2027-01-01", 1)
             ])

    assert %{"data" => %{"revision" => 1, "credit_paid_cents" => 0}} =
             get(conn, "/api/v1/groups/group") |> json_response(200)

    assert %{"error" => %{"code" => "invalid_date"}} =
             get(conn, "/api/v1/ledger?on=yesterday") |> json_response(422)

    assert %{"error" => %{"code" => "invalid_date"}} =
             get(conn, "/api/v1/guests/guest/credit?on=yesterday") |> json_response(422)
  end
end
