defmodule GroupStayWeb.DepositTransferTest do
  use GroupStayWeb.ConnCase

  defp post_operations(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open(group_id, guest_id \\ "guest-1") do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-01-01",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "hotel-#{group_id}",
      "arrival_on" => "2026-05-01",
      "departure_on" => "2026-05-02",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "a", "nightly_rate_cents" => 10_000},
        %{"room_id" => "b", "nightly_rate_cents" => 20_000}
      ]
    }
  end

  defp payment(id, group_id, amount) do
    %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-01-02",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp transfer(id, source, destination, amount) do
    %{
      "operation_id" => id,
      "type" => "transfer_deposit",
      "occurred_on" => "2026-01-03",
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount
    }
  end

  defp group(group_id) do
    build_conn()
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp statement(payment_id) do
    build_conn()
    |> get("/api/v1/payments/#{payment_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "moves newest funding first, reports both revisions, and replays idempotently" do
    post_operations([
      open("source"),
      open("destination"),
      payment("pay-1", "source", 3_000),
      payment("pay-2", "source", 2_000)
    ])

    operation =
      transfer("transfer", "source", "destination", 2_500)
      |> Map.put("expected_revision", 3)
      |> Map.put("destination_expected_revision", 1)

    assert [result] = post_operations([operation])

    assert result == %{
             "operation_id" => "transfer",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 2_500,
             "source_outstanding_deposit_cents" => 3_500,
             "destination_outstanding_deposit_cents" => 3_500,
             "source_revision" => 4,
             "destination_revision" => 2
           }

    assert [%{"cash_paid_cents" => 2_000}, %{"cash_paid_cents" => 500}] =
             group("source")["rooms"]

    assert [%{"cash_paid_cents" => 2_000}, %{"cash_paid_cents" => 500}] =
             group("destination")["rooms"]

    assert statement("pay-1")["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 500},
             %{"group_id" => "source", "amount_cents" => 2_500}
           ]

    assert statement("pay-2")["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 2_000}
           ]

    assert post_operations([operation]) == [result]
    assert group("source")["revision"] == 4
    assert group("destination")["revision"] == 2

    ledger = get(build_conn(), "/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
    assert ledger["cash_held_cents"] == 5_000
  end

  test "reductions and chargebacks follow transferred cash and revise every changed group" do
    post_operations([
      open("source"),
      open("destination"),
      payment("pay-1", "source", 3_000),
      payment("pay-2", "source", 2_000),
      transfer("transfer", "source", "destination", 2_500)
    ])

    assert [%{"status" => "applied", "revision" => 5}] =
             post_operations([
               %{
                 "operation_id" => "reduce",
                 "type" => "reduce_cash_payment",
                 "occurred_on" => "2026-01-04",
                 "payment_operation_id" => "pay-1",
                 "amount_cents" => 1_000,
                 "expected_revision" => 4
               }
             ])

    assert group("source")["revision"] == 5
    assert group("destination")["revision"] == 3
    assert group("source")["cash_paid_cents"] == 2_000
    assert group("destination")["cash_paid_cents"] == 2_000

    assert statement("pay-1")["held_by_group"] == [
             %{"group_id" => "source", "amount_cents" => 2_000}
           ]

    assert [%{"status" => "applied", "revision" => 6, "charged_back_cents" => 2_000}] =
             post_operations([
               %{
                 "operation_id" => "chargeback",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-01-05",
                 "payment_operation_id" => "pay-2",
                 "expected_revision" => 5
               }
             ])

    assert group("source")["revision"] == 6
    assert group("destination")["revision"] == 4
    assert group("destination")["cash_paid_cents"] == 0
    assert statement("pay-2")["held_by_group"] == []
  end

  test "preserves hotel-credit lots and settles transferred funding under the destination policy" do
    post_operations([
      open("credit-origin"),
      payment("origin-payment", "credit-origin", 4_000),
      %{
        "operation_id" => "issue-credit",
        "type" => "cancel_group",
        "occurred_on" => "2026-03-18",
        "group_id" => "credit-origin",
        "refund_method" => "hotel_credit"
      },
      open("source"),
      open("destination"),
      payment("source-payment", "source", 1_000),
      %{
        "operation_id" => "apply-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-03-19",
        "group_id" => "source",
        "amount_cents" => 2_000
      }
    ])

    before_transfer =
      get(build_conn(), "/api/v1/ledger?on=2026-03-20")
      |> json_response(200)
      |> Map.fetch!("data")

    post_operations([transfer("transfer-mixed", "source", "destination", 2_500)])

    after_transfer =
      get(build_conn(), "/api/v1/ledger?on=2026-03-20")
      |> json_response(200)
      |> Map.fetch!("data")

    assert after_transfer == before_transfer
    assert group("source")["cash_paid_cents"] == 500
    assert group("source")["credit_paid_cents"] == 0
    assert group("destination")["cash_paid_cents"] == 500
    assert group("destination")["credit_paid_cents"] == 2_000

    assert [%{"refunded_cents" => 500, "credit_issued_cents" => 0}] =
             post_operations([
               %{
                 "operation_id" => "cancel-destination",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-03-20",
                 "group_id" => "destination"
               }
             ])

    credit =
      get(build_conn(), "/api/v1/guests/guest-1/credit?on=2026-03-20")
      |> json_response(200)
      |> Map.fetch!("data")

    assert credit["available_cents"] == 4_400

    assert [%{"source_operation_id" => "issue-credit", "remaining_cents" => 4_400}] =
             credit["lots"]
  end

  test "rejects in the specified lookup, revision, and domain-validation order" do
    post_operations([open("source"), open("destination"), open("other-guest", "guest-2")])

    assert [%{"code" => "group_not_found", "group_id" => "missing-source"}] =
             post_operations([transfer("missing-source", "missing-source", "missing-dest", 1)])

    assert [%{"code" => "group_not_found", "group_id" => "missing-dest"}] =
             post_operations([transfer("missing-dest", "source", "missing-dest", 1)])

    assert [
             %{
               "code" => "stale_revision",
               "group_id" => "source",
               "expected_revision" => 9,
               "actual_revision" => 1
             }
           ] =
             post_operations([
               transfer("stale-source", "source", "other-guest", 0)
               |> Map.put("expected_revision", 9)
             ])

    assert [%{"code" => "stale_revision", "group_id" => "destination"}] =
             post_operations([
               transfer("stale-destination", "source", "destination", 0)
               |> Map.put("destination_expected_revision", 9)
             ])

    assert [%{"code" => "invalid_transfer"}] =
             post_operations([transfer("same", "source", "source", 1)])

    assert [%{"code" => "invalid_transfer"}] =
             post_operations([transfer("different-guests", "source", "other-guest", 1)])

    assert [%{"code" => "invalid_amount"}] =
             post_operations([transfer("invalid-amount", "source", "destination", 0)])

    assert [%{"code" => "transfer_exceeds_held_funding"}] =
             post_operations([transfer("too-much-funding", "source", "destination", 1)])

    post_operations([payment("fill-destination", "destination", 6_000)])

    assert [%{"code" => "transfer_exceeds_outstanding"}] =
             post_operations([
               payment("fund-source", "source", 1_000),
               transfer("too-much-outstanding", "source", "destination", 1)
             ])
             |> Enum.drop(1)

    post_operations([
      %{
        "operation_id" => "cancel-source",
        "type" => "cancel_group",
        "occurred_on" => "2026-04-20",
        "group_id" => "source"
      }
    ])

    assert [%{"code" => "group_not_active", "group_id" => "source"}] =
             post_operations([transfer("inactive-source", "source", "destination", 1)])
  end
end
