defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  defp opening(id, extra \\ %{}) do
    Map.merge(
      %{
        "type" => "open_group",
        "operation_id" => "open-#{id}",
        "group_id" => id,
        "guest_id" => "guest",
        "property_id" => "hotel",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 10000}]
      },
      extra
    )
  end

  defp op(type, id, extra) do
    Map.merge(
      %{
        "type" => type,
        "operation_id" => "#{type}-#{id}-#{System.unique_integer([:positive])}",
        "group_id" => id,
        "occurred_on" => "2027-02-01"
      },
      extra
    )
  end

  defp batch(ops) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => ops})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp read(path),
    do: build_conn() |> get("/api/v1/" <> path) |> json_response(200) |> Map.fetch!("data")

  defp credit(on \\ "2027-02-01"), do: read("guests/guest/credit?on=#{on}")
  defp ledger(on \\ "2027-02-01"), do: read("ledger?on=#{on}")

  defp issue(id, amount, extra \\ %{}) do
    batch([
      opening(id),
      op("record_cash_payment", id, %{"amount_cents" => amount}),
      op(
        "cancel_group",
        id,
        Map.merge(
          %{"refund_method" => "hotel_credit", "operation_id" => "cancel_group-#{id}"},
          extra
        )
      )
    ])
  end

  test "booking cutoff fixes policy and rescheduling recomputes inclusive refund deadline" do
    for {id, booked, policy, deadline, late} <- [
          {"old", "2026-12-31", "flex-14", "2028-02-16", "2028-02-17"},
          {"new", "2027-01-01", "flex-30", "2028-01-31", "2028-02-01"}
        ] do
      batch([
        opening(id, %{"occurred_on" => booked}),
        op("record_cash_payment", id, %{"amount_cents" => 100})
      ])

      assert [
               %{
                 "policy_version" => ^policy,
                 "refundable_until" => ^deadline,
                 "new_departure_on" => "2028-03-02"
               }
             ] =
               batch([
                 op("reschedule_group", id, %{"new_arrival_on" => "2028-03-01"})
               ])

      assert read("groups/#{id}")["policy_version"] == policy

      assert [%{"code" => "refund_method_not_available"}] =
               batch([
                 op("cancel_group", id, %{
                   "occurred_on" => late,
                   "refund_method" => "hotel_credit"
                 })
               ])

      assert [%{"refunded_cents" => 100, "credit_issued_cents" => 0, "revision" => 4}] =
               batch([
                 op("cancel_group", id, %{"occurred_on" => deadline})
               ])
    end

    batch([opening("advance", %{"rate_plan" => "advance_purchase"})])

    assert %{"policy_version" => "advance-nonrefundable", "refundable_until" => nil} =
             read("groups/advance")

    assert [%{"code" => "refund_method_not_available"}] =
             batch([
               op("cancel_group", "advance", %{"refund_method" => "hotel_credit"})
             ])
  end

  test "cash conversion rounds bonus half upward and moves cash to a separate ledger total" do
    assert [_, _, %{"refunded_cents" => 0, "retained_cents" => 0, "credit_issued_cents" => 6}] =
             issue("source", 5)

    assert credit() == %{
             "guest_id" => "guest",
             "available_cents" => 6,
             "lots" => [
               %{
                 "source_operation_id" => "cancel_group-source",
                 "remaining_cents" => 6,
                 "expires_on" => "2028-02-01"
               }
             ]
           }

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 5,
             "credit_liability_cents" => 6
           }

    assert credit("2028-02-01")["available_cents"] == 6
    assert credit("2028-02-02")["lots"] == []
    assert ledger("2028-02-02")["credit_liability_cents"] == 0
    # As-of reads never mutate balances.
    assert credit()["available_cents"] == 6
    assert read("guests/missing/credit")["lots"] == []
    assert read("guests/guest/credit") == credit(Date.to_iso8601(Date.utc_today()))
    assert read("ledger") == ledger(Date.to_iso8601(Date.utc_today()))
  end

  test "mixed funding restores original credit and only bonuses newly converted cash" do
    issue("source", 100)

    assert [_, %{"revision" => 2}, %{"revision" => 3, "outstanding_deposit_cents" => 1890}] =
             batch([
               opening("target"),
               op("record_cash_payment", "target", %{"amount_cents" => 50}),
               op("apply_hotel_credit", "target", %{
                 "amount_cents" => 60,
                 "expected_revision" => 2
               })
             ])

    assert %{"deposit_paid_cents" => 110, "cash_paid_cents" => 50, "credit_paid_cents" => 60} =
             read("groups/target")

    assert credit()["available_cents"] == 50
    assert ledger()["credit_liability_cents"] == 110

    assert [%{"credit_issued_cents" => 55, "refunded_cents" => 0, "revision" => 4}] =
             batch([
               op("cancel_group", "target", %{"refund_method" => "hotel_credit"})
             ])

    assert Enum.map(credit()["lots"], & &1["remaining_cents"]) == [110, 55]
    assert ledger()["cash_converted_to_credit_cents"] == 150
    assert ledger()["credit_liability_cents"] == 165

    assert %{"deposit_paid_cents" => 0, "cash_paid_cents" => 0, "credit_paid_cents" => 0} =
             read("groups/target")
  end

  test "credit uses earliest expiry then operation identifier, and expiry pauses while applied" do
    issue("z", 100)
    issue("a", 100)
    issue("earlier", 100, %{"occurred_on" => "2027-01-31"})

    batch([
      opening("target", %{"arrival_on" => "2029-06-01", "departure_on" => "2029-06-02"}),
      op("apply_hotel_credit", "target", %{"amount_cents" => 150})
    ])

    assert Enum.map(credit()["lots"], &{&1["source_operation_id"], &1["remaining_cents"]}) == [
             {"cancel_group-a", 70},
             {"cancel_group-z", 110}
           ]

    assert ledger("2028-02-02")["credit_liability_cents"] == 150
    batch([op("cancel_group", "target", %{"occurred_on" => "2028-02-01"})])
    # Earlier lot expires immediately on restoration; equal-date lot remains usable.
    assert credit("2028-02-01")["available_cents"] == 220
    assert ledger("2028-02-01")["credit_liability_cents"] == 220
    assert ledger("2028-02-02")["credit_liability_cents"] == 0
  end

  test "refundable cash settlement restores credit without bonus; late cancellation consumes it" do
    issue("source", 200)

    for {id, date, refund, retain, liability} <- [
          {"refundable", "2027-05-02", 50, 0, 220},
          {"late", "2027-05-03", 0, 50, 120}
        ] do
      assert [
               _,
               _,
               _,
               %{
                 "refunded_cents" => ^refund,
                 "retained_cents" => ^retain,
                 "credit_issued_cents" => 0
               }
             ] =
               batch([
                 opening(id),
                 op("apply_hotel_credit", id, %{"amount_cents" => 100}),
                 op("record_cash_payment", id, %{"amount_cents" => 50}),
                 op("cancel_group", id, %{"occurred_on" => date})
               ])

      assert ledger()["credit_liability_cents"] == liability
    end
  end

  test "rejected credit and refund operations leave all accounting unchanged and batch continues" do
    issue("source", 100)
    batch([opening("target"), opening("other", %{"guest_id" => "another"})])
    before = {credit(), ledger(), read("groups/target")}

    for {extra, code} <- [
          {%{}, "invalid_operation"},
          {%{"amount_cents" => 0}, "invalid_amount"},
          {%{"amount_cents" => -1}, "invalid_amount"},
          {%{"amount_cents" => 1.5}, "invalid_amount"},
          {%{"amount_cents" => "1"}, "invalid_amount"},
          {%{"amount_cents" => nil}, "invalid_amount"},
          {%{"amount_cents" => 2001}, "payment_exceeds_outstanding"},
          {%{"amount_cents" => 111}, "insufficient_credit"},
          {%{"amount_cents" => 1, "occurred_on" => "2028-02-02"}, "insufficient_credit"},
          {%{"amount_cents" => 1, "group_id" => "other"}, "insufficient_credit"},
          {%{"amount_cents" => 9999, "expected_revision" => 0}, "stale_revision"},
          {%{"group_id" => "missing", "expected_revision" => 0}, "group_not_found"}
        ] do
      assert [%{"code" => ^code}] = batch([op("apply_hotel_credit", "target", extra)])
      assert {credit(), ledger(), read("groups/target")} == before
    end

    assert [
             %{"code" => "stale_revision"},
             %{"code" => "invalid_operation"},
             %{"revision" => 2},
             %{"revision" => 3},
             %{"code" => "group_not_active"}
           ] =
             batch([
               op("cancel_group", "target", %{"refund_method" => "bad", "expected_revision" => 0}),
               op("cancel_group", "target", %{"refund_method" => "bad"}),
               op("apply_hotel_credit", "target", %{
                 "amount_cents" => 110,
                 "expected_revision" => 1
               }),
               op("cancel_group", "target", %{"expected_revision" => 2}),
               op("apply_hotel_credit", "target", %{"amount_cents" => 1})
             ])
  end

  test "invalid as-of dates return a controlled error" do
    for path <- ["ledger?on=bad", "guests/guest/credit?on=2027-02-30", "ledger?on[]=x"] do
      assert build_conn() |> get("/api/v1/" <> path) |> json_response(422) == %{
               "error" => %{"code" => "invalid_date"}
             }
    end
  end

  test "credit can be redeemed on expiry and advance-purchase cancellation consumes it" do
    assert [_, _, %{"credit_issued_cents" => 4}] = issue("small", 4)
    batch([opening("advance", %{"rate_plan" => "advance_purchase"})])

    assert [%{"revision" => 2}] =
             batch([
               op("apply_hotel_credit", "advance", %{
                 "amount_cents" => 4,
                 "occurred_on" => "2028-02-01"
               })
             ])

    assert credit("2028-02-01")["lots"] == []
    assert ledger("2028-02-02")["credit_liability_cents"] == 4

    assert [%{"retained_cents" => 0, "refunded_cents" => 0, "credit_issued_cents" => 0}] =
             batch([op("cancel_group", "advance", %{"occurred_on" => "2028-02-02"})])

    assert ledger("2028-02-02")["credit_liability_cents"] == 0
  end

  test "credit-only hotel-credit cancellation restores without issuing a second bonus" do
    issue("source", 100)
    batch([opening("target"), op("apply_hotel_credit", "target", %{"amount_cents" => 110})])

    assert [%{"credit_issued_cents" => 0}] =
             batch([
               op("cancel_group", "target", %{"refund_method" => "hotel_credit"})
             ])

    assert length(credit()["lots"]) == 1
    assert credit()["available_cents"] == 110
    assert ledger()["cash_converted_to_credit_cents"] == 100

    assert [_, %{"credit_issued_cents" => 0}] =
             batch([
               opening("unfunded"),
               op("cancel_group", "unfunded", %{"refund_method" => "hotel_credit"})
             ])

    assert length(credit()["lots"]) == 1
  end
end
