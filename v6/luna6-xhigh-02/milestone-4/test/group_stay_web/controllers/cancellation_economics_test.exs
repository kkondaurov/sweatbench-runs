defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open_operation(operation_id, group_id, booked_on, arrival_on, rate_plan \\ "flexible") do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => booked_on,
      "group_id" => group_id,
      "guest_id" => "guest-credit",
      "property_id" => "ams-canal",
      "arrival_on" => arrival_on,
      "departure_on" => Date.add(Date.from_iso8601!(arrival_on), 1) |> Date.to_iso8601(),
      "rate_plan" => rate_plan,
      "rooms" => [%{"room_id" => "room-1", "nightly_rate_cents" => 1_000}]
    }
  end

  defp payment(operation_id, group_id, occurred_on, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancel(operation_id, group_id, occurred_on, refund_method \\ nil) do
    operation = %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }

    if refund_method, do: Map.put(operation, "refund_method", refund_method), else: operation
  end

  defp apply_credit(operation_id, group_id, occurred_on, amount, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "apply_hotel_credit",
        "occurred_on" => occurred_on,
        "group_id" => group_id,
        "amount_cents" => amount
      },
      extra
    )
  end

  test "assigns the booking-date cancellation policy and keeps it when rescheduled", %{conn: conn} do
    old_policy = open_operation("open-old", "old-policy", "2026-12-31", "2027-03-01")
    new_policy = open_operation("open-new", "new-policy", "2027-01-01", "2027-03-01")

    advance =
      open_operation("open-advance", "advance", "2027-01-01", "2027-03-01", "advance_purchase")

    late_policy = open_operation("open-late", "late-policy", "2027-01-01", "2027-03-01")

    move = %{
      "operation_id" => "move-old",
      "type" => "reschedule_group",
      "occurred_on" => "2027-01-01",
      "group_id" => "old-policy",
      "new_arrival_on" => "2027-04-01"
    }

    results =
      submit(conn, [
        old_policy,
        new_policy,
        advance,
        payment("pay-new", "new-policy", "2027-01-01", 10),
        cancel("cancel-new", "new-policy", "2027-01-30"),
        late_policy,
        payment("pay-late", "late-policy", "2027-01-01", 10),
        cancel("cancel-late", "late-policy", "2027-01-31"),
        move
      ])

    assert %{
             "operation_id" => "cancel-new",
             "status" => "applied",
             "refunded_cents" => 10,
             "retained_cents" => 0
           } = Enum.at(results, 4)

    assert %{
             "operation_id" => "cancel-late",
             "status" => "applied",
             "refunded_cents" => 0,
             "retained_cents" => 10
           } = Enum.at(results, 7)

    assert %{
             "status" => "applied",
             "policy_version" => "flex-14",
             "refundable_until" => "2027-03-18",
             "new_arrival_on" => "2027-04-01"
           } = Enum.at(results, 8)

    assert %{"data" => old_group} = conn |> get("/api/v1/groups/old-policy") |> json_response(200)
    assert old_group["policy_version"] == "flex-14"
    assert old_group["refundable_until"] == "2027-03-18"

    assert %{"data" => new_group} = conn |> get("/api/v1/groups/new-policy") |> json_response(200)
    assert new_group["policy_version"] == "flex-30"
    assert new_group["refundable_until"] == "2027-01-30"

    assert %{"data" => advance_group} =
             conn |> get("/api/v1/groups/advance") |> json_response(200)

    assert advance_group["policy_version"] == "advance-nonrefundable"
    assert advance_group["refundable_until"] == nil
  end

  test "converts cash to ordered hotel credit and pauses expiry while applied", %{conn: conn} do
    source_z = open_operation("open-z", "source-z-group", "2027-01-01", "2027-03-10")
    source_a = open_operation("open-a", "source-a-group", "2027-01-01", "2027-03-10")

    operations = [
      source_z,
      payment("pay-z", "source-z-group", "2027-01-01", 101),
      cancel("source-z", "source-z-group", "2027-01-02", "hotel_credit"),
      source_a,
      payment("pay-a", "source-a-group", "2027-01-01", 105),
      cancel("source-a", "source-a-group", "2027-01-02", "hotel_credit")
    ]

    assert [_, _, %{"credit_issued_cents" => 111}, _, _, %{"credit_issued_cents" => 116}] =
             submit(conn, operations)

    assert %{"data" => %{"available_cents" => 227, "lots" => lots}} =
             conn |> get("/api/v1/guests/guest-credit/credit?on=2027-01-02") |> json_response(200)

    assert Enum.map(lots, & &1["source_operation_id"]) == ["source-a", "source-z"]
    assert Enum.map(lots, & &1["remaining_cents"]) == [116, 111]
    assert Enum.all?(lots, &(&1["expires_on"] == "2028-01-02"))

    assert %{"data" => ledger} =
             conn |> get("/api/v1/ledger?on=2027-01-02") |> json_response(200)

    assert ledger["cash_held_cents"] == 0
    assert ledger["cash_converted_to_credit_cents"] == 206
    assert ledger["credit_liability_cents"] == 227

    target = open_operation("open-target", "target", "2027-01-03", "2027-05-01")
    assert [%{"revision" => 1}] = submit(conn, [target])

    assert [
             %{"status" => "applied", "revision" => 2, "outstanding_deposit_cents" => 100},
             %{"status" => "applied", "revision" => 3, "outstanding_deposit_cents" => 50}
           ] =
             submit(conn, [
               apply_credit("use-credit-first", "target", "2027-01-04", 100),
               apply_credit("use-credit-second", "target", "2027-01-04", 50)
             ])

    assert %{"data" => target_group} = conn |> get("/api/v1/groups/target") |> json_response(200)
    assert target_group["deposit_paid_cents"] == 150
    assert target_group["cash_paid_cents"] == 0
    assert target_group["credit_paid_cents"] == 150

    assert %{
             "data" => %{
               "lots" => [%{"source_operation_id" => "source-z", "remaining_cents" => 77}]
             }
           } =
             conn |> get("/api/v1/guests/guest-credit/credit?on=2027-01-04") |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 227}} =
             conn |> get("/api/v1/ledger?on=2027-01-04") |> json_response(200)

    assert [%{"status" => "applied", "revision" => 4}] =
             submit(conn, [payment("top-up", "target", "2027-01-04", 20)])

    assert %{"data" => target_group} = conn |> get("/api/v1/groups/target") |> json_response(200)
    assert target_group["deposit_paid_cents"] == 170
    assert target_group["cash_paid_cents"] == 20
    assert target_group["credit_paid_cents"] == 150

    assert [%{"status" => "applied", "refunded_cents" => 0, "credit_issued_cents" => 22}] =
             submit(conn, [cancel("cancel-target", "target", "2027-01-05", "hotel_credit")])

    assert %{"data" => %{"available_cents" => 249, "lots" => restored_lots}} =
             conn |> get("/api/v1/guests/guest-credit/credit?on=2027-01-05") |> json_response(200)

    assert Enum.map(restored_lots, & &1["source_operation_id"]) == [
             "source-a",
             "source-z",
             "cancel-target"
           ]

    assert Enum.map(restored_lots, & &1["remaining_cents"]) == [116, 111, 22]

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_converted_to_credit_cents" => 226,
               "credit_liability_cents" => 249
             }
           } = conn |> get("/api/v1/ledger?on=2027-01-05") |> json_response(200)

    expires_while_applied =
      open_operation("open-expiry", "expiry-group", "2027-01-06", "2028-06-01")

    assert [%{"status" => "applied"}] = submit(conn, [expires_while_applied])

    assert [%{"status" => "applied", "revision" => 2}] =
             submit(conn, [apply_credit("use-before-expiry", "expiry-group", "2028-01-02", 111)])

    assert %{"data" => %{"credit_liability_cents" => 133}} =
             conn |> get("/api/v1/ledger?on=2028-01-03") |> json_response(200)

    assert [%{"status" => "applied", "credit_issued_cents" => 0}] =
             submit(conn, [cancel("cancel-after-expiry", "expiry-group", "2028-01-03")])

    assert %{
             "data" => %{
               "available_cents" => 22,
               "lots" => [%{"source_operation_id" => "cancel-target", "remaining_cents" => 22}]
             }
           } =
             conn |> get("/api/v1/guests/guest-credit/credit?on=2028-01-03") |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 22}} =
             conn |> get("/api/v1/ledger?on=2028-01-03") |> json_response(200)
  end

  test "rejects unavailable credit refunds and consumes credit at nonrefundable cancellation", %{
    conn: conn
  } do
    source = open_operation("open-source", "source", "2027-01-01", "2027-03-01")

    target =
      open_operation(
        "open-advance",
        "advance-target",
        "2027-01-02",
        "2027-03-01",
        "advance_purchase"
      )

    assert [_, _, %{"credit_issued_cents" => 110}, _] =
             submit(conn, [
               source,
               payment("source-payment", "source", "2027-01-01", 100),
               cancel("source-cancel", "source", "2027-01-02", "hotel_credit"),
               target
             ])

    assert [%{"status" => "rejected", "code" => "insufficient_credit"}] =
             submit(conn, [apply_credit("too-much", "advance-target", "2027-01-03", 111)])

    assert [%{"status" => "rejected", "code" => "stale_revision", "actual_revision" => 1}] =
             submit(conn, [
               apply_credit("stale-credit", "advance-target", "2027-01-03", 111, %{
                 "expected_revision" => 0
               })
             ])

    assert [%{"status" => "applied", "revision" => 2}] =
             submit(conn, [apply_credit("apply-some", "advance-target", "2027-01-03", 100)])

    assert [%{"status" => "rejected", "code" => "refund_method_not_available"}] =
             submit(conn, [
               cancel("bad-credit-refund", "advance-target", "2027-01-04", "hotel_credit")
             ])

    assert %{"data" => %{"status" => "active", "revision" => 2}} =
             conn |> get("/api/v1/groups/advance-target") |> json_response(200)

    assert [
             %{
               "status" => "applied",
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }
           ] =
             submit(conn, [cancel("consume-credit", "advance-target", "2027-01-04")])

    assert %{"data" => %{"credit_liability_cents" => 10}} =
             conn |> get("/api/v1/ledger?on=2027-01-04") |> json_response(200)

    assert %{"data" => %{"available_cents" => 10}} =
             conn |> get("/api/v1/guests/guest-credit/credit?on=2027-01-04") |> json_response(200)
  end
end
