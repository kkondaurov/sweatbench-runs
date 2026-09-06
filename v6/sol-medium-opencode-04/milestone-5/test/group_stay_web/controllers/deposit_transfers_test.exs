defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  defp post_operations(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open(operation_id, group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-03-10",
        "departure_on" => "2027-03-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 10_000}
        ]
      },
      overrides
    )
  end

  defp payment(group_id, operation_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp transfer(operation_id, source, destination, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => "2026-12-01",
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount
    }
  end

  defp group(conn, group_id) do
    conn
    |> get(~p"/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "moves newest mixed funding first, preserves provenance, and is durably idempotent", %{
    conn: conn
  } do
    issue_credit = [
      open("open-issuer", "issuer"),
      payment("issuer", "issuer-pay", 2_000),
      %{
        "operation_id" => "issue-credit",
        "type" => "cancel_group",
        "occurred_on" => "2026-12-01",
        "group_id" => "issuer",
        "refund_method" => "hotel_credit"
      }
    ]

    apply_credit = %{
      "operation_id" => "apply-credit",
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-12-01",
      "group_id" => "source",
      "amount_cents" => 2_000
    }

    operation =
      transfer("move", "source", "destination", 4_000)
      |> Map.put("expected_revision", 3)
      |> Map.put("destination_expected_revision", 1)

    assert [_, _, _, _, _, _, _, moved] =
             post_operations(
               conn,
               issue_credit ++
                 [
                   open("open-source", "source"),
                   open("open-destination", "destination"),
                   payment("source", "source-pay", 3_000),
                   apply_credit,
                   operation
                 ]
             )

    assert moved == %{
             "operation_id" => "move",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 4_000,
             "source_outstanding_deposit_cents" => 11_000,
             "destination_outstanding_deposit_cents" => 8_000,
             "source_revision" => 4,
             "destination_revision" => 2
           }

    source = group(conn, "source")
    destination = group(conn, "destination")
    assert {source["cash_paid_cents"], source["credit_paid_cents"]} == {1_000, 0}
    assert {destination["cash_paid_cents"], destination["credit_paid_cents"]} == {2_000, 2_000}
    assert hd(destination["rooms"])["cash_paid_cents"] == 2_000
    assert hd(destination["rooms"])["credit_paid_cents"] == 2_000

    statement =
      conn |> get(~p"/api/v1/payments/source-pay") |> json_response(200) |> Map.fetch!("data")

    assert statement["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 2_000},
             %{"group_id" => "source", "amount_cents" => 1_000}
           ]

    ledger_before = conn |> get(~p"/api/v1/ledger?on=2026-12-01") |> json_response(200)
    assert [replayed] = post_operations(conn, [operation])
    assert replayed == moved
    assert group(conn, "source")["revision"] == 4
    assert group(conn, "destination")["revision"] == 2
    assert conn |> get(~p"/api/v1/ledger?on=2026-12-01") |> json_response(200) == ledger_before
  end

  test "resolves both groups and revision guards before transfer validation", %{conn: conn} do
    assert [_, _, missing_destination, stale_source, stale_destination, same_group] =
             post_operations(conn, [
               open("open-source", "source"),
               open("open-destination", "destination"),
               transfer("missing-destination", "source", "missing", -1),
               transfer("stale-source", "source", "destination", -1)
               |> Map.put("expected_revision", 0)
               |> Map.put("destination_expected_revision", 0),
               transfer("stale-destination", "source", "destination", -1)
               |> Map.put("expected_revision", 1)
               |> Map.put("destination_expected_revision", 0),
               transfer("same", "source", "source", 1)
             ])

    assert missing_destination == %{
             "operation_id" => "missing-destination",
             "status" => "rejected",
             "code" => "group_not_found",
             "group_id" => "missing"
           }

    assert stale_source["code"] == "stale_revision"
    assert stale_source["group_id"] == "source"
    assert stale_destination["code"] == "stale_revision"
    assert stale_destination["group_id"] == "destination"
    assert same_group["code"] == "invalid_transfer"
    assert group(conn, "source")["revision"] == 1
    assert group(conn, "destination")["revision"] == 1
  end

  test "rejects inactive, cross-guest, and capacity-invalid transfers without state changes", %{
    conn: conn
  } do
    other_guest = open("open-other", "other", %{"guest_id" => "guest-other"})

    assert [
             _,
             _,
             _,
             cross_guest,
             invalid_amount,
             no_funding,
             _,
             _,
             no_capacity,
             _,
             inactive
           ] =
             post_operations(conn, [
               open("open-source", "source"),
               open("open-destination", "destination"),
               other_guest,
               transfer("cross-guest", "source", "other", 1),
               transfer("invalid-amount", "source", "destination", 0),
               transfer("no-funding", "source", "destination", 1),
               payment("destination", "fill-destination", 12_000),
               payment("source", "fund-source", 1_000),
               transfer("no-capacity", "source", "destination", 1),
               %{
                 "operation_id" => "cancel-destination",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-12-01",
                 "group_id" => "destination"
               },
               transfer("inactive", "source", "destination", 1)
             ])

    assert cross_guest["code"] == "invalid_transfer"
    assert invalid_amount["code"] == "invalid_amount"
    assert no_funding["code"] == "transfer_exceeds_held_funding"
    assert no_capacity["code"] == "transfer_exceeds_outstanding"
    assert inactive["code"] == "group_not_active"
    assert inactive["group_id"] == "destination"
  end

  test "reductions follow transferred cash and revise every changed group once", %{conn: conn} do
    reduction = %{
      "operation_id" => "reduce",
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-12-02",
      "payment_operation_id" => "pay",
      "amount_cents" => 4_000,
      "expected_revision" => 3
    }

    assert [_, _, _, _, reduced] =
             post_operations(conn, [
               open("open-source", "source"),
               open("open-destination", "destination"),
               payment("source", "pay", 6_000),
               transfer("move", "source", "destination", 3_000),
               reduction
             ])

    assert reduced["revision"] == 4
    assert reduced["outstanding_deposit_cents"] == 10_000
    assert group(conn, "destination")["revision"] == 3
    assert group(conn, "destination")["cash_paid_cents"] == 0
    assert group(conn, "source")["cash_paid_cents"] == 2_000

    statement = conn |> get(~p"/api/v1/payments/pay") |> json_response(200) |> Map.fetch!("data")
    assert statement["held_by_group"] == [%{"group_id" => "source", "amount_cents" => 2_000}]
  end

  test "chargebacks reclassify cash settled under the destination policy", %{conn: conn} do
    advance = open("open-destination", "destination", %{"rate_plan" => "advance_purchase"})

    cancel_destination = %{
      "operation_id" => "cancel-destination",
      "type" => "cancel_group",
      "occurred_on" => "2026-12-02",
      "group_id" => "destination"
    }

    chargeback = %{
      "operation_id" => "chargeback",
      "type" => "charge_back_payment",
      "occurred_on" => "2026-12-03",
      "payment_operation_id" => "__legacy__:pay",
      "expected_revision" => 3
    }

    assert [_, _, _, _, cancelled, charged] =
             post_operations(conn, [
               open("open-source", "source"),
               advance,
               payment("source", "__legacy__:pay", 5_000),
               transfer("move", "source", "destination", 3_000),
               cancel_destination,
               chargeback
             ])

    assert cancelled["retained_cents"] == 3_000
    assert charged["charged_back_cents"] == 5_000
    assert charged["revision"] == 4
    assert group(conn, "destination")["revision"] == 4

    ledger = conn |> get(~p"/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
    assert ledger["cash_held_cents"] == 0
    assert ledger["cash_retained_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 5_000

    statement =
      conn
      |> get(~p"/api/v1/payments/__legacy__:pay")
      |> json_response(200)
      |> Map.fetch!("data")

    assert statement["held_by_group"] == []
  end

  test "transferred credit restores to its original lot without revaluation", %{conn: conn} do
    cancel_issuer = %{
      "operation_id" => "issue",
      "type" => "cancel_group",
      "occurred_on" => "2026-12-01",
      "group_id" => "issuer",
      "refund_method" => "hotel_credit"
    }

    use_credit = %{
      "operation_id" => "use",
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-12-01",
      "group_id" => "source",
      "amount_cents" => 2_000
    }

    cancel_destination = %{
      "operation_id" => "return",
      "type" => "cancel_group",
      "occurred_on" => "2026-12-02",
      "group_id" => "destination"
    }

    assert [_, _, _, _, _, _, _, returned] =
             post_operations(conn, [
               open("open-issuer", "issuer"),
               payment("issuer", "__legacy__:partner-payment", 2_000),
               cancel_issuer,
               open("open-source", "source"),
               open("open-destination", "destination"),
               use_credit,
               transfer("move", "source", "destination", 2_000),
               cancel_destination
             ])

    assert returned["credit_issued_cents"] == 0

    credit =
      conn
      |> get(~p"/api/v1/guests/guest-22/credit?on=2026-12-02")
      |> json_response(200)
      |> Map.fetch!("data")

    assert credit["available_cents"] == 2_200

    assert credit["lots"] == [
             %{
               "source_operation_id" => "issue",
               "remaining_cents" => 2_200,
               "expires_on" => "2027-12-01"
             }
           ]

    assert [%{"status" => "applied"}] =
             post_operations(conn, [
               %{
                 "operation_id" => "chargeback",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-12-03",
                 "payment_operation_id" => "__legacy__:partner-payment"
               }
             ])

    revoked =
      conn
      |> get(~p"/api/v1/guests/guest-22/credit?on=2026-12-03")
      |> json_response(200)
      |> Map.fetch!("data")

    assert revoked["available_cents"] == 0
  end
end
