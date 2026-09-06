defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  defp open(operation_id, group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-01-20",
        "departure_on" => "2027-01-22",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 25_000}]
      },
      overrides
    )
  end

  defp payment(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancel(operation_id, group_id, occurred_on, overrides \\ %{}) do
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

  defp apply_credit(operation_id, group_id, amount, occurred_on, overrides \\ %{}) do
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

  test "fixes policy at booking cutover and recomputes its date when rescheduled", %{conn: conn} do
    [legacy, modern, advance, moved] =
      submit(conn, [
        open("open-old", "old"),
        open("open-new", "new", %{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-15",
          "departure_on" => "2027-03-17"
        }),
        open("open-advance", "advance", %{"rate_plan" => "advance_purchase"}),
        %{
          "operation_id" => "move-old",
          "type" => "reschedule_group",
          "occurred_on" => "2026-11-01",
          "group_id" => "old",
          "new_arrival_on" => "2027-02-20"
        }
      ])

    assert legacy["status"] == "applied"
    assert modern["status"] == "applied"
    assert advance["status"] == "applied"
    assert moved["policy_version"] == "flex-14"
    assert moved["refundable_until"] == "2027-02-06"

    old = conn |> get("/api/v1/groups/old") |> json_response(200) |> Map.fetch!("data")
    new = conn |> get("/api/v1/groups/new") |> json_response(200) |> Map.fetch!("data")
    advance = conn |> get("/api/v1/groups/advance") |> json_response(200) |> Map.fetch!("data")

    assert {old["policy_version"], old["refundable_until"]} == {"flex-14", "2027-02-06"}
    assert {new["policy_version"], new["refundable_until"]} == {"flex-30", "2027-02-13"}

    assert {advance["policy_version"], advance["refundable_until"]} ==
             {"advance-nonrefundable", nil}
  end

  test "converts refundable cash to a bonused lot and reports expiry", %{conn: conn} do
    [_, _, result] =
      submit(conn, [
        open("open-source", "source"),
        payment("pay-source", "source", 5_005),
        cancel("credit-source", "source", "2026-12-01", %{"refund_method" => "hotel_credit"})
      ])

    assert result["refunded_cents"] == 0
    assert result["retained_cents"] == 0
    assert result["credit_issued_cents"] == 5_506

    credit =
      conn
      |> get("/api/v1/guests/guest-22/credit?on=2027-12-01")
      |> json_response(200)
      |> Map.fetch!("data")

    assert credit == %{
             "guest_id" => "guest-22",
             "available_cents" => 5_506,
             "lots" => [
               %{
                 "source_operation_id" => "credit-source",
                 "remaining_cents" => 5_506,
                 "expires_on" => "2027-12-01"
               }
             ]
           }

    expired =
      conn
      |> get("/api/v1/guests/guest-22/credit?on=2027-12-02")
      |> json_response(200)
      |> Map.fetch!("data")

    assert expired["available_cents"] == 0
    assert expired["lots"] == []

    ledger =
      conn |> get("/api/v1/ledger?on=2027-12-01") |> json_response(200) |> Map.fetch!("data")

    assert ledger["cash_converted_to_credit_cents"] == 5_005
    assert ledger["cash_refunded_cents"] == 0
    assert ledger["cash_retained_cents"] == 0
    assert ledger["credit_liability_cents"] == 5_506
  end

  test "applies earliest-expiring lots and tracks cash and credit separately", %{conn: conn} do
    operations = [
      open("open-first", "first"),
      payment("pay-first", "first", 5_000),
      cancel("z-later-expiry", "first", "2026-11-02", %{"refund_method" => "hotel_credit"}),
      open("open-second", "second"),
      payment("pay-second", "second", 5_000),
      cancel("z-earlier-expiry", "second", "2026-11-01", %{"refund_method" => "hotel_credit"}),
      open("open-third", "third"),
      payment("pay-third", "third", 5_000),
      cancel("a-earlier-expiry", "third", "2026-11-01", %{"refund_method" => "hotel_credit"}),
      open("open-target", "target"),
      payment("cash-target", "target", 1_000),
      apply_credit("use-credit", "target", 6_000, "2027-01-01")
    ]

    results = submit(conn, operations)
    assert List.last(results)["outstanding_deposit_cents"] == 3_000
    assert List.last(results)["revision"] == 3

    target = conn |> get("/api/v1/groups/target") |> json_response(200) |> Map.fetch!("data")
    assert target["deposit_paid_cents"] == 7_000
    assert target["cash_paid_cents"] == 1_000
    assert target["credit_paid_cents"] == 6_000

    credit =
      conn
      |> get("/api/v1/guests/guest-22/credit?on=2027-01-01")
      |> json_response(200)
      |> Map.fetch!("data")

    assert Enum.map(credit["lots"], &{&1["source_operation_id"], &1["remaining_cents"]}) == [
             {"z-earlier-expiry", 5_000},
             {"z-later-expiry", 5_500}
           ]

    ledger =
      conn |> get("/api/v1/ledger?on=2027-01-01") |> json_response(200) |> Map.fetch!("data")

    assert ledger["credit_liability_cents"] == 16_500
    assert ledger["cash_held_cents"] == 1_000
  end

  test "restores applied credit without a bonus and drops it if its original expiry passed", %{
    conn: conn
  } do
    submit(conn, [
      open("open-source", "source"),
      payment("pay-source", "source", 5_000),
      cancel("source-credit", "source", "2026-11-01", %{"refund_method" => "hotel_credit"}),
      open("open-target", "target", %{
        "arrival_on" => "2027-12-01",
        "departure_on" => "2027-12-03"
      }),
      apply_credit("use-credit-1", "target", 2_500, "2027-10-01"),
      apply_credit("use-credit-2", "target", 3_000, "2027-10-02")
    ])

    before_cancel =
      conn |> get("/api/v1/ledger?on=2027-11-02") |> json_response(200) |> Map.fetch!("data")

    assert before_cancel["credit_liability_cents"] == 5_500

    [result] = submit(conn, [cancel("cancel-target", "target", "2027-11-02")])
    assert result["credit_issued_cents"] == 0
    assert result["refunded_cents"] == 0
    assert result["retained_cents"] == 0

    credit =
      conn
      |> get("/api/v1/guests/guest-22/credit?on=2027-11-02")
      |> json_response(200)
      |> Map.fetch!("data")

    assert credit["available_cents"] == 0

    ledger =
      conn |> get("/api/v1/ledger?on=2027-11-02") |> json_response(200) |> Map.fetch!("data")

    assert ledger["credit_liability_cents"] == 0
  end

  test "combines multiple applications back into the original unexpired lot", %{conn: conn} do
    submit(conn, [
      open("open-source", "source"),
      payment("pay-source", "source", 5_000),
      cancel("source-credit", "source", "2027-01-01", %{"refund_method" => "hotel_credit"}),
      open("open-target", "target", %{
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-03"
      }),
      apply_credit("use-credit-1", "target", 2_500, "2027-02-01"),
      apply_credit("use-credit-2", "target", 3_000, "2027-02-02"),
      cancel("cancel-target", "target", "2027-05-18")
    ])

    credit =
      conn
      |> get("/api/v1/guests/guest-22/credit?on=2027-05-18")
      |> json_response(200)
      |> Map.fetch!("data")

    assert credit["available_cents"] == 5_500

    assert credit["lots"] == [
             %{
               "source_operation_id" => "source-credit",
               "remaining_cents" => 5_500,
               "expires_on" => "2028-01-01"
             }
           ]
  end

  test "rejects unavailable refund methods and credit failures without advancing revision", %{
    conn: conn
  } do
    [_, unavailable, stale, insufficient] =
      submit(conn, [
        open("open-advance", "advance", %{"rate_plan" => "advance_purchase"}),
        cancel("bad-refund", "advance", "2026-11-01", %{
          "refund_method" => "hotel_credit"
        }),
        apply_credit("stale", "advance", -1, "2026-11-01", %{"expected_revision" => 99}),
        apply_credit("no-credit", "advance", 100, "2026-11-01", %{
          "expected_revision" => 1
        })
      ])

    assert unavailable["code"] == "refund_method_not_available"
    assert stale["code"] == "stale_revision"
    assert insufficient["code"] == "insufficient_credit"

    group = conn |> get("/api/v1/groups/advance") |> json_response(200) |> Map.fetch!("data")
    assert group["status"] == "active"
    assert group["revision"] == 1
  end

  test "consumes applied credit on a non-refundable cancellation", %{conn: conn} do
    submit(conn, [
      open("open-source", "source"),
      payment("pay-source", "source", 5_000),
      cancel("source-credit", "source", "2026-11-01", %{"refund_method" => "hotel_credit"}),
      open("open-advance", "advance", %{"rate_plan" => "advance_purchase"}),
      apply_credit("use-credit", "advance", 5_500, "2027-01-01"),
      cancel("cancel-advance", "advance", "2027-01-02")
    ])

    ledger =
      conn |> get("/api/v1/ledger?on=2027-01-02") |> json_response(200) |> Map.fetch!("data")

    assert ledger["credit_liability_cents"] == 0
    assert ledger["cash_retained_cents"] == 0
  end

  test "rejects invalid report dates", %{conn: conn} do
    assert conn |> get("/api/v1/ledger?on=nope") |> json_response(422) ==
             %{"error" => %{"code" => "invalid_date"}}

    assert conn |> get("/api/v1/guests/guest-22/credit?on=nope") |> json_response(422) ==
             %{"error" => %{"code" => "invalid_date"}}
  end
end
