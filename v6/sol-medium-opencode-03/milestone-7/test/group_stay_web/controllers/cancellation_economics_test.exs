defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  defp open(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-12-31",
        "group_id" => group_id,
        "guest_id" => "guest-1",
        "property_id" => "hotel-1",
        "arrival_on" => "2027-03-31",
        "departure_on" => "2027-04-01",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-1", "nightly_rate_cents" => 50_000}]
      },
      overrides
    )
  end

  defp operation(type, operation_id, group_id, occurred_on, attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => type,
        "occurred_on" => occurred_on,
        "group_id" => group_id
      },
      attrs
    )
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  test "fixes the policy at booking and recomputes its date after rescheduling", %{conn: conn} do
    [_, _, moved] =
      submit(conn, [
        open("old"),
        open("new", %{
          "operation_id" => "open-new",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-04-01",
          "departure_on" => "2027-04-02"
        }),
        operation("reschedule_group", "move-new", "new", "2027-01-02", %{
          "new_arrival_on" => "2027-05-01"
        })
      ])

    assert moved == %{
             "operation_id" => "move-new",
             "status" => "applied",
             "group_id" => "new",
             "new_arrival_on" => "2027-05-01",
             "new_departure_on" => "2027-05-02",
             "policy_version" => "flex-30",
             "refundable_until" => "2027-04-01",
             "revision" => 2
           }

    old = build_conn() |> get("/api/v1/groups/old") |> json_response(200) |> Map.fetch!("data")
    new = build_conn() |> get("/api/v1/groups/new") |> json_response(200) |> Map.fetch!("data")

    assert {old["policy_version"], old["refundable_until"]} == {"flex-14", "2027-03-17"}
    assert {new["policy_version"], new["refundable_until"]} == {"flex-30", "2027-04-01"}

    [advance] =
      submit(build_conn(), [
        open("advance", %{"rate_plan" => "advance_purchase", "operation_id" => "open-advance"})
      ])

    assert advance["status"] == "applied"

    advance_group =
      build_conn() |> get("/api/v1/groups/advance") |> json_response(200) |> Map.fetch!("data")

    assert advance_group["policy_version"] == "advance-nonrefundable"
    assert advance_group["refundable_until"] == nil
  end

  test "uses the inclusive 30-day cancellation boundary", %{conn: conn} do
    [_, _, cancellation] =
      submit(conn, [
        open("boundary", %{"occurred_on" => "2027-01-01"}),
        operation("record_cash_payment", "pay", "boundary", "2027-01-02", %{
          "amount_cents" => 1_000
        }),
        operation("cancel_group", "cancel", "boundary", "2027-03-01")
      ])

    assert cancellation["refunded_cents"] == 1_000
    assert cancellation["retained_cents"] == 0
  end

  test "converts refundable cash to a rounded credit lot and reports expiry", %{conn: conn} do
    [_, _, cancellation] =
      submit(conn, [
        open("source"),
        operation("record_cash_payment", "pay-source", "source", "2027-01-01", %{
          "amount_cents" => 1_005
        }),
        operation("cancel_group", "credit-source", "source", "2027-03-17", %{
          "refund_method" => "hotel_credit"
        })
      ])

    assert cancellation["refunded_cents"] == 0
    assert cancellation["retained_cents"] == 0
    assert cancellation["credit_issued_cents"] == 1_106

    assert build_conn()
           |> get("/api/v1/guests/guest-1/credit?on=2028-03-16")
           |> json_response(200) == %{
             "data" => %{
               "guest_id" => "guest-1",
               "available_cents" => 1_106,
               "lots" => [
                 %{
                   "source_operation_id" => "credit-source",
                   "remaining_cents" => 1_106,
                   "expires_on" => "2028-03-17"
                 }
               ]
             }
           }

    assert build_conn()
           |> get("/api/v1/guests/guest-1/credit?on=2028-03-17")
           |> json_response(200) == %{
             "data" => %{"guest_id" => "guest-1", "available_cents" => 0, "lots" => []}
           }

    ledger = build_conn() |> get("/api/v1/ledger?on=2028-03-16") |> json_response(200)
    assert ledger["data"]["cash_converted_to_credit_cents"] == 1_005
    assert ledger["data"]["cash_refunded_cents"] == 0
    assert ledger["data"]["cash_retained_cents"] == 0
    assert ledger["data"]["credit_liability_cents"] == 1_106
  end

  test "rejects unavailable refund methods after revision checking", %{conn: conn} do
    [_, stale, unavailable] =
      submit(conn, [
        open("advance", %{"rate_plan" => "advance_purchase"}),
        operation("cancel_group", "stale", "advance", "2027-01-01", %{
          "refund_method" => "hotel_credit",
          "expected_revision" => 9
        }),
        operation("cancel_group", "unavailable", "advance", "2027-01-01", %{
          "refund_method" => "hotel_credit",
          "expected_revision" => 1
        })
      ])

    assert stale["code"] == "stale_revision"
    assert unavailable["code"] == "refund_method_not_available"

    group =
      build_conn() |> get("/api/v1/groups/advance") |> json_response(200) |> Map.fetch!("data")

    assert group["status"] == "active"
    assert group["revision"] == 1
  end

  test "applies earliest credit and restores it without another bonus", %{conn: conn} do
    operations = [
      open("first"),
      operation("record_cash_payment", "pay-first", "first", "2027-01-01", %{
        "amount_cents" => 1_000
      }),
      operation("cancel_group", "lot-b", "first", "2027-03-17", %{
        "refund_method" => "hotel_credit"
      }),
      open("second"),
      operation("record_cash_payment", "pay-second", "second", "2027-01-01", %{
        "amount_cents" => 2_000
      }),
      operation("cancel_group", "lot-a", "second", "2027-03-17", %{
        "refund_method" => "hotel_credit"
      }),
      open("target", %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-02"
      }),
      operation("record_cash_payment", "pay-target", "target", "2027-04-01", %{
        "amount_cents" => 1_005,
        "expected_revision" => 1
      }),
      operation("apply_hotel_credit", "use-credit", "target", "2027-04-01", %{
        "amount_cents" => 1_500,
        "expected_revision" => 2
      })
    ]

    results = submit(conn, operations)
    applied = List.last(results)
    assert applied["status"] == "applied"
    assert applied["outstanding_deposit_cents"] == 7_495
    assert applied["revision"] == 3

    target =
      build_conn() |> get("/api/v1/groups/target") |> json_response(200) |> Map.fetch!("data")

    assert target["deposit_paid_cents"] == 2_505
    assert target["cash_paid_cents"] == 1_005
    assert target["credit_paid_cents"] == 1_500

    credit =
      build_conn()
      |> get("/api/v1/guests/guest-1/credit?on=2027-04-01")
      |> json_response(200)
      |> Map.fetch!("data")

    assert credit["lots"] == [
             %{
               "source_operation_id" => "lot-a",
               "remaining_cents" => 700,
               "expires_on" => "2028-03-17"
             },
             %{
               "source_operation_id" => "lot-b",
               "remaining_cents" => 1_100,
               "expires_on" => "2028-03-17"
             }
           ]

    assert build_conn()
           |> get("/api/v1/ledger?on=2027-04-01")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 3_300

    [restored] =
      submit(build_conn(), [
        operation("cancel_group", "cancel-target", "target", "2027-05-01", %{
          "refund_method" => "hotel_credit",
          "expected_revision" => 3
        })
      ])

    assert restored["refunded_cents"] == 0
    assert restored["retained_cents"] == 0
    assert restored["credit_issued_cents"] == 1_106

    restored_credit =
      build_conn()
      |> get("/api/v1/guests/guest-1/credit?on=2027-05-01")
      |> json_response(200)
      |> Map.fetch!("data")

    assert restored_credit["available_cents"] == 4_406

    assert Enum.find(restored_credit["lots"], &(&1["source_operation_id"] == "cancel-target")) ==
             %{
               "source_operation_id" => "cancel-target",
               "remaining_cents" => 1_106,
               "expires_on" => "2028-05-01"
             }
  end

  test "validates credit amounts and consumes applied credit on non-refundable cancellation", %{
    conn: conn
  } do
    results =
      submit(conn, [
        open("source"),
        operation("record_cash_payment", "pay-source", "source", "2027-01-01", %{
          "amount_cents" => 1_000
        }),
        operation("cancel_group", "lot", "source", "2027-03-17", %{
          "refund_method" => "hotel_credit"
        }),
        open("advance", %{"rate_plan" => "advance_purchase", "occurred_on" => "2027-01-01"}),
        operation("apply_hotel_credit", "bad-amount", "advance", "2027-04-01", %{
          "amount_cents" => 0
        }),
        operation("apply_hotel_credit", "too-much", "advance", "2027-04-01", %{
          "amount_cents" => 99_999
        }),
        operation("apply_hotel_credit", "insufficient", "advance", "2027-04-01", %{
          "amount_cents" => 1_101,
          "expected_revision" => 1
        }),
        operation("apply_hotel_credit", "use", "advance", "2027-04-01", %{
          "amount_cents" => 1_100,
          "expected_revision" => 1
        }),
        operation("cancel_group", "cancel-advance", "advance", "2027-04-02", %{
          "expected_revision" => 2
        })
      ])

    assert Enum.at(results, 4)["code"] == "invalid_amount"
    assert Enum.at(results, 5)["code"] == "payment_exceeds_outstanding"
    assert Enum.at(results, 6)["code"] == "insufficient_credit"
    assert Enum.at(results, 7)["revision"] == 2
    assert Enum.at(results, 8)["retained_cents"] == 0

    assert build_conn()
           |> get("/api/v1/ledger?on=2027-04-02")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 0
  end

  test "expired credit restored from a refundable group reduces liability immediately", %{
    conn: conn
  } do
    submit(conn, [
      open("source"),
      operation("record_cash_payment", "pay", "source", "2027-01-01", %{
        "amount_cents" => 1_000
      }),
      operation("cancel_group", "lot", "source", "2027-03-17", %{
        "refund_method" => "hotel_credit"
      }),
      open("target", %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2028-05-01",
        "departure_on" => "2028-05-02"
      }),
      operation("apply_hotel_credit", "use", "target", "2028-03-16", %{
        "amount_cents" => 1_100
      })
    ])

    assert build_conn()
           |> get("/api/v1/ledger?on=2028-03-17")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 1_100

    [cancelled] =
      submit(build_conn(), [operation("cancel_group", "restore", "target", "2028-03-18")])

    assert cancelled["refunded_cents"] == 0

    assert build_conn()
           |> get("/api/v1/ledger?on=2028-03-18")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 0
  end

  test "rejects invalid report dates", %{conn: conn} do
    assert conn |> get("/api/v1/ledger?on=bad") |> json_response(422) == %{
             "error" => %{"code" => "invalid_date"}
           }

    assert build_conn() |> get("/api/v1/guests/guest-1/credit?on=bad") |> json_response(422) == %{
             "error" => %{"code" => "invalid_date"}
           }
  end
end
