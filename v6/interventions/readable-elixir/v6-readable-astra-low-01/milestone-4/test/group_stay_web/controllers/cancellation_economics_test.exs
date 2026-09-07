defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  defp operation(type, group, fields \\ %{}) do
    Map.merge(
      %{
        "type" => type,
        "group_id" => group,
        "operation_id" => "#{type}-#{group}-#{System.unique_integer([:positive])}",
        "occurred_on" => "2027-02-01"
      },
      fields
    )
  end

  defp open(group, fields \\ %{}) do
    operation(
      "open_group",
      group,
      Map.merge(
        %{
          "guest_id" => "guest",
          "property_id" => "hotel",
          "arrival_on" => "2027-04-01",
          "departure_on" => "2027-04-02",
          "rate_plan" => "flexible",
          "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 100_000}]
        },
        fields
      )
    )
  end

  defp batch(operations) do
    build_conn()
    |> post("/api/v1/partner-batches", %{operations: operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp read(path),
    do: build_conn() |> get("/api/v1/" <> path) |> json_response(200) |> Map.fetch!("data")

  defp credit(on \\ "2027-02-01"), do: read("guests/guest/credit?on=" <> on)
  defp ledger(on \\ "2027-02-01"), do: read("ledger?on=" <> on)

  defp issue(group, cash, fields \\ %{}) do
    batch([
      open(group),
      operation("record_cash_payment", group, %{"amount_cents" => cash}),
      operation(
        "cancel_group",
        group,
        Map.merge(
          %{"refund_method" => "hotel_credit", "operation_id" => "cancel_group-#{group}"},
          fields
        )
      )
    ])
  end

  test "policy selection, inclusive deadlines and fixed policy on rescheduling" do
    for {id, booked, policy, cutoff} <- [
          {"old", "2026-12-31", "flex-14", "2027-03-18"},
          {"new", "2027-01-01", "flex-30", "2027-03-02"}
        ] do
      batch([open(id, %{"occurred_on" => booked})])
      assert %{"policy_version" => ^policy, "refundable_until" => ^cutoff} = read("groups/" <> id)
      [moved] = batch([operation("reschedule_group", id, %{"new_arrival_on" => "2028-04-01"})])
      assert moved["policy_version"] == policy
      assert moved["new_departure_on"] == "2028-04-02"
      assert moved["refundable_until"] == String.replace(cutoff, "2027", "2028")
    end

    for {id, on, refunded} <- [{"boundary", "2027-03-02", 100}, {"late", "2027-03-03", 0}] do
      [_, _, cancelled] =
        batch([
          open(id),
          operation("record_cash_payment", id, %{"amount_cents" => 100}),
          operation("cancel_group", id, %{"occurred_on" => on})
        ])

      assert cancelled["refunded_cents"] == refunded
      assert cancelled["retained_cents"] == 100 - refunded
    end

    batch([open("advance", %{"rate_plan" => "advance_purchase"})])

    assert %{"policy_version" => "advance-nonrefundable", "refundable_until" => nil} =
             read("groups/advance")
  end

  test "cash conversion rounds bonus upward and expires after the inclusive anniversary" do
    assert [_, _, %{"credit_issued_cents" => 116, "refunded_cents" => 0, "retained_cents" => 0}] =
             issue("source", 105)

    assert credit()["available_cents"] == 116

    assert [%{"source_operation_id" => "cancel_group-source", "expires_on" => "2028-02-01"}] =
             credit()["lots"]

    assert credit("2028-02-01")["available_cents"] == 116
    assert credit("2028-02-02") == %{"guest_id" => "guest", "available_cents" => 0, "lots" => []}
    assert ledger()["cash_converted_to_credit_cents"] == 105
    assert ledger()["cash_held_cents"] == 0
    assert ledger("2028-02-02")["credit_liability_cents"] == 0
    assert read("guests/unknown/credit")["available_cents"] == 0
  end

  test "mixed funding restores original credit without another bonus and converts only cash" do
    issue("source", 100)

    assert [_, %{"revision" => 2}, %{"outstanding_deposit_cents" => 19850}] =
             batch([
               open("target"),
               operation("apply_hotel_credit", "target", %{
                 "amount_cents" => 100,
                 "expected_revision" => 1
               }),
               operation("record_cash_payment", "target", %{"amount_cents" => 50})
             ])

    assert %{"deposit_paid_cents" => 150, "cash_paid_cents" => 50, "credit_paid_cents" => 100} =
             read("groups/target")

    assert credit()["available_cents"] == 10
    assert ledger()["credit_liability_cents"] == 110
    assert ledger()["cash_held_cents"] == 50

    assert [%{"credit_issued_cents" => 55, "revision" => 4}] =
             batch([
               operation("cancel_group", "target", %{
                 "refund_method" => "hotel_credit",
                 "expected_revision" => 3
               })
             ])

    assert credit()["available_cents"] == 165
    assert ledger()["credit_liability_cents"] == 165
    assert ledger()["cash_converted_to_credit_cents"] == 150
  end

  test "allocation ordering, paused expiry and immediate expiry on restoration" do
    issue("z", 100, %{"operation_id" => "z"})
    issue("a", 100, %{"operation_id" => "a"})
    issue("earlier", 100, %{"operation_id" => "earlier", "occurred_on" => "2027-01-31"})
    batch([open("target"), operation("apply_hotel_credit", "target", %{"amount_cents" => 150})])

    assert Enum.map(credit()["lots"], &{&1["source_operation_id"], &1["remaining_cents"]}) == [
             {"a", 70},
             {"z", 110}
           ]

    assert ledger("2028-02-02")["credit_liability_cents"] == 150

    batch([
      operation("reschedule_group", "target", %{
        "occurred_on" => "2028-02-02",
        "new_arrival_on" => "2028-06-01"
      }),
      operation("cancel_group", "target", %{"occurred_on" => "2028-02-02"})
    ])

    assert ledger("2028-02-02")["credit_liability_cents"] == 0
    assert credit("2028-02-02")["available_cents"] == 0
  end

  test "refundable cash settlement restores credit; nonrefundable settlement consumes it" do
    for {id, on, available, retained} <- [
          {"refund", "2027-03-02", 110, 0},
          {"retain", "2027-03-03", 120, 50}
        ] do
      issue("source-" <> id, 100)

      batch([
        open(id),
        operation("apply_hotel_credit", id, %{"amount_cents" => 100}),
        operation("record_cash_payment", id, %{"amount_cents" => 50})
      ])

      assert [%{"retained_cents" => ^retained, "credit_issued_cents" => 0}] =
               batch([operation("cancel_group", id, %{"occurred_on" => on})])

      assert credit()["available_cents"] == available
      assert ledger()["credit_liability_cents"] == available
    end
  end

  test "rejections are atomic, revision checks precede credit rules, and batches continue" do
    issue("source", 100)
    batch([open("target"), open("other", %{"guest_id" => "other"})])
    before = {credit(), ledger(), read("groups/target")}

    for {fields, code} <- [
          {%{"amount_cents" => 111}, "insufficient_credit"},
          {%{"amount_cents" => 20001}, "payment_exceeds_outstanding"},
          {%{"amount_cents" => 0}, "invalid_amount"},
          {%{"amount_cents" => 111, "expected_revision" => 0}, "stale_revision"},
          {%{"amount_cents" => 1, "occurred_on" => "2028-02-02"}, "insufficient_credit"}
        ] do
      assert [%{"code" => ^code}] = batch([operation("apply_hotel_credit", "target", fields)])
      assert {credit(), ledger(), read("groups/target")} == before
    end

    assert [%{"code" => "insufficient_credit"}] =
             batch([operation("apply_hotel_credit", "other", %{"amount_cents" => 1})])

    assert [%{"code" => "group_not_found"}] =
             batch([
               operation("apply_hotel_credit", "missing", %{
                 "amount_cents" => 1,
                 "expected_revision" => 99
               })
             ])

    assert [
             %{"code" => "stale_revision"},
             %{"code" => "refund_method_not_available"},
             %{"code" => "invalid_operation"},
             %{"revision" => 2}
           ] =
             batch([
               operation("cancel_group", "target", %{
                 "refund_method" => "hotel_credit",
                 "occurred_on" => "2027-03-03",
                 "expected_revision" => 0
               }),
               operation("cancel_group", "target", %{
                 "refund_method" => "hotel_credit",
                 "occurred_on" => "2027-03-03"
               }),
               operation("cancel_group", "target", %{"refund_method" => "unknown"}),
               operation("apply_hotel_credit", "target", %{
                 "amount_cents" => 110,
                 "expected_revision" => 1
               })
             ])

    batch([operation("cancel_group", "target")])

    assert [%{"code" => "group_not_active"}] =
             batch([operation("apply_hotel_credit", "target", %{"amount_cents" => 1})])
  end

  test "credit can be redeemed and restored on its final valid day" do
    issue("source", 100)

    batch([
      open("target", %{"arrival_on" => "2028-04-01", "departure_on" => "2028-04-02"}),
      operation("apply_hotel_credit", "target", %{
        "amount_cents" => 110,
        "occurred_on" => "2028-02-01"
      })
    ])

    assert credit("2028-02-01")["lots"] == []
    assert ledger("2028-02-01")["credit_liability_cents"] == 110

    assert [%{"credit_issued_cents" => 0}] =
             batch([
               operation("cancel_group", "target", %{
                 "occurred_on" => "2028-02-01",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert [%{"remaining_cents" => 110, "source_operation_id" => "cancel_group-source"}] =
             credit("2028-02-01")["lots"]

    assert ledger("2028-02-02")["credit_liability_cents"] == 0
  end

  test "advance purchase cannot convert cash and unpaid cancellation creates no lot" do
    batch([
      open("advance", %{"rate_plan" => "advance_purchase"}),
      operation("record_cash_payment", "advance", %{"amount_cents" => 100})
    ])

    before = {read("groups/advance"), ledger()}

    assert [%{"code" => "refund_method_not_available"}] =
             batch([
               operation("cancel_group", "advance", %{"refund_method" => "hotel_credit"})
             ])

    assert {read("groups/advance"), ledger()} == before

    assert [_, %{"credit_issued_cents" => 0}] =
             batch([
               open("unpaid"),
               operation("cancel_group", "unpaid", %{"refund_method" => "hotel_credit"})
             ])

    assert credit()["lots"] == []
    assert read("ledger") == ledger(Date.to_iso8601(Date.utc_today()))
    assert read("guests/guest/credit") == credit(Date.to_iso8601(Date.utc_today()))
  end

  test "invalid read dates return a client error" do
    for path <- ["ledger", "guests/guest/credit"] do
      assert build_conn() |> get("/api/v1/" <> path <> "?on=bad") |> json_response(422) == %{
               "error" => %{"code" => "invalid_date"}
             }
    end
  end
end
