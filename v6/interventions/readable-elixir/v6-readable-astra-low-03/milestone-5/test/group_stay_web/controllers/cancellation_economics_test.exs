defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  defp open(id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{id}",
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => id,
        "guest_id" => "guest",
        "property_id" => "hotel",
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10000}]
      },
      overrides
    )
  end

  defp op(type, id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "#{type}-#{id}-#{System.unique_integer([:positive])}",
        "type" => type,
        "group_id" => id,
        "occurred_on" => "2027-02-01"
      },
      overrides
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

  defp credit(on \\ "2027-02-01"), do: read("guests/guest/credit?on=" <> on)
  defp ledger(on \\ "2027-02-01"), do: read("ledger?on=" <> on)

  defp issue(id, amount, overrides \\ %{}) do
    assert [%{"status" => "applied"}, %{"status" => "applied"}, %{"status" => "applied"} = result] =
             batch([
               open(id),
               op("record_cash_payment", id, %{"amount_cents" => amount}),
               op(
                 "cancel_group",
                 id,
                 Map.merge(
                   %{"refund_method" => "hotel_credit", "operation_id" => "cancel_group-#{id}"},
                   overrides
                 )
               )
             ])

    result
  end

  test "booking policy is fixed and deadlines are inclusive after rescheduling" do
    for {id, booked, plan, version, deadline} <- [
          {"old", "2026-12-31", "flexible", "flex-14", "2028-05-18"},
          {"new", "2027-01-01", "flexible", "flex-30", "2028-05-02"},
          {"advance", "2026-12-31", "advance_purchase", "advance-nonrefundable", nil}
        ] do
      batch([open(id, %{"occurred_on" => booked, "rate_plan" => plan})])
      assert %{"policy_version" => ^version} = read("groups/#{id}")

      assert [
               %{
                 "revision" => 2,
                 "policy_version" => ^version,
                 "refundable_until" => ^deadline,
                 "new_departure_on" => "2028-06-02"
               }
             ] =
               batch([op("reschedule_group", id, %{"new_arrival_on" => "2028-06-01"})])

      batch([op("record_cash_payment", id, %{"amount_cents" => 100})])
      date = deadline || "2027-02-01"
      expected = if deadline, do: 100, else: 0

      assert [%{"refunded_cents" => ^expected}] =
               batch([op("cancel_group", id, %{"occurred_on" => date})])
    end

    batch([open("late"), op("record_cash_payment", "late", %{"amount_cents" => 100})])

    assert [%{"retained_cents" => 100}] =
             batch([op("cancel_group", "late", %{"occurred_on" => "2027-05-03"})])
  end

  test "cash conversion rounds half cents upward and expires the day after its anniversary" do
    assert %{"credit_issued_cents" => 6, "refunded_cents" => 0, "retained_cents" => 0} =
             issue("source", 5)

    assert %{
             "available_cents" => 6,
             "lots" => [
               %{
                 "source_operation_id" => "cancel_group-source",
                 "remaining_cents" => 6,
                 "expires_on" => "2028-02-01"
               }
             ]
           } = credit("2028-02-01")

    assert %{"available_cents" => 0, "lots" => []} = credit("2028-02-02")

    assert %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 5,
             "credit_liability_cents" => 6
           } = ledger("2028-02-01")

    assert ledger("2028-02-02")["credit_liability_cents"] == 0
    assert read("guests/missing/credit")["lots"] == []
    assert read("guests/guest/credit") == credit(Date.to_iso8601(Date.utc_today()))
    assert read("ledger") == ledger(Date.to_iso8601(Date.utc_today()))
  end

  test "lots fund deposits in expiry and source order and refundable settlement restores them" do
    issue("z", 100)
    issue("a", 100)
    issue("early", 100, %{"occurred_on" => "2027-01-31"})

    assert Enum.map(credit()["lots"], & &1["source_operation_id"]) == [
             "cancel_group-early",
             "cancel_group-a",
             "cancel_group-z"
           ]

    assert [
             %{"revision" => 1},
             %{"revision" => 2, "outstanding_deposit_cents" => 1850},
             %{"revision" => 3}
           ] =
             batch([
               open("target"),
               op("apply_hotel_credit", "target", %{"amount_cents" => 150}),
               op("record_cash_payment", "target", %{"amount_cents" => 100})
             ])

    assert %{"cash_paid_cents" => 100, "credit_paid_cents" => 150, "deposit_paid_cents" => 250} =
             read("groups/target")

    assert Enum.map(credit()["lots"], &{&1["source_operation_id"], &1["remaining_cents"]}) == [
             {"cancel_group-a", 70},
             {"cancel_group-z", 110}
           ]

    assert ledger()["credit_liability_cents"] == 330
    assert ledger()["cash_held_cents"] == 100

    assert [%{"revision" => 4, "credit_issued_cents" => 0, "refunded_cents" => 100}] =
             batch([op("cancel_group", "target")])

    assert credit()["available_cents"] == 330
    assert ledger()["credit_liability_cents"] == 330
    assert read("groups/target")["credit_paid_cents"] == 0
  end

  test "redeemed credit pauses expiry and expired restorations immediately reduce liability" do
    issue("source", 100)

    batch([
      open("target", %{"arrival_on" => "2028-06-01", "departure_on" => "2028-06-02"}),
      op("apply_hotel_credit", "target", %{"amount_cents" => 80, "occurred_on" => "2028-02-01"})
    ])

    assert ledger("2028-02-02")["credit_liability_cents"] == 80
    assert credit("2028-02-02")["available_cents"] == 0

    assert [%{"credit_issued_cents" => 0, "refunded_cents" => 0}] =
             batch([
               op("cancel_group", "target", %{
                 "refund_method" => "hotel_credit",
                 "occurred_on" => "2028-02-02"
               })
             ])

    assert ledger("2028-02-02")["credit_liability_cents"] == 0
    assert credit("2028-02-02")["lots"] == []
  end

  test "restored credit receives no second bonus and nonrefundable cancellation consumes it" do
    issue("source", 100)

    batch([
      open("mixed"),
      op("apply_hotel_credit", "mixed", %{"amount_cents" => 110}),
      op("record_cash_payment", "mixed", %{"amount_cents" => 50})
    ])

    assert [%{"credit_issued_cents" => 55, "refunded_cents" => 0, "retained_cents" => 0}] =
             batch([op("cancel_group", "mixed", %{"refund_method" => "hotel_credit"})])

    assert credit()["available_cents"] == 165

    batch([
      open("nonref", %{"rate_plan" => "advance_purchase"}),
      op("apply_hotel_credit", "nonref", %{"amount_cents" => 165}),
      op("record_cash_payment", "nonref", %{"amount_cents" => 20})
    ])

    assert [%{"credit_issued_cents" => 0, "refunded_cents" => 0, "retained_cents" => 20}] =
             batch([op("cancel_group", "nonref")])

    assert ledger()["credit_liability_cents"] == 0
    assert ledger()["cash_converted_to_credit_cents"] == 150
    assert credit()["lots"] == []
  end

  test "rejected operations preserve balances and revisions and processing continues" do
    issue("source", 100)
    batch([open("target", %{"guest_id" => "other"})])
    before = read("groups/target")
    balances = ledger()

    for {attrs, code} <- [
          {%{"amount_cents" => 1, "expected_revision" => 0}, "stale_revision"},
          {%{"amount_cents" => 1}, "insufficient_credit"},
          {%{"amount_cents" => 2001}, "payment_exceeds_outstanding"},
          {%{"amount_cents" => 0}, "invalid_amount"},
          {%{"amount_cents" => -1}, "invalid_amount"},
          {%{"amount_cents" => 1.5}, "invalid_amount"},
          {%{"amount_cents" => "1"}, "invalid_amount"},
          {%{"amount_cents" => nil}, "invalid_amount"},
          {%{"amount_cents" => 1, "group_id" => "missing", "expected_revision" => 0},
           "group_not_found"}
        ] do
      assert [%{"code" => ^code}] = batch([op("apply_hotel_credit", "target", attrs)])
      assert read("groups/target") == before
      assert ledger() == balances
    end

    assert [
             %{"code" => "stale_revision"},
             %{"code" => "refund_method_not_available"},
             %{"code" => "invalid_operation"},
             %{"revision" => 2}
           ] =
             batch([
               op("cancel_group", "target", %{
                 "refund_method" => "hotel_credit",
                 "occurred_on" => "2027-05-03",
                 "expected_revision" => 0
               }),
               op("cancel_group", "target", %{
                 "refund_method" => "hotel_credit",
                 "occurred_on" => "2027-05-03"
               }),
               op("cancel_group", "target", %{"refund_method" => "unknown"}),
               op("record_cash_payment", "target", %{
                 "amount_cents" => 1,
                 "expected_revision" => 1
               })
             ])

    batch([open("expired")])

    assert [%{"code" => "insufficient_credit"}] =
             batch([
               op("apply_hotel_credit", "expired", %{
                 "amount_cents" => 1,
                 "occurred_on" => "2028-02-02"
               })
             ])

    assert [%{"code" => "group_not_active"}] =
             batch([op("apply_hotel_credit", "source", %{"amount_cents" => 1})])

    assert credit()["available_cents"] == 110
  end

  test "insufficient attempts do not consume partial balances and later operations see revisions" do
    issue("source", 100)
    batch([open("target")])
    before = credit()

    assert [%{"code" => "insufficient_credit"}] =
             batch([op("apply_hotel_credit", "target", %{"amount_cents" => 111})])

    assert credit() == before
    assert read("groups/target")["revision"] == 1

    assert [
             %{"revision" => 2},
             %{"code" => "stale_revision", "actual_revision" => 2},
             %{"revision" => 3}
           ] =
             batch([
               op("apply_hotel_credit", "target", %{
                 "amount_cents" => 50,
                 "expected_revision" => 1
               }),
               op("apply_hotel_credit", "target", %{
                 "amount_cents" => 60,
                 "expected_revision" => 1
               }),
               op("apply_hotel_credit", "target", %{
                 "amount_cents" => 60,
                 "expected_revision" => 2
               })
             ])

    assert credit()["available_cents"] == 0
    assert ledger()["credit_liability_cents"] == 110
    assert read("groups/target")["credit_paid_cents"] == 110
    batch([op("cancel_group", "target")])
    assert credit() == before
  end

  test "credit restored on its expiry date remains available with its original expiry" do
    issue("source", 100)

    batch([
      open("target", %{"arrival_on" => "2028-06-01", "departure_on" => "2028-06-02"}),
      op("apply_hotel_credit", "target", %{"amount_cents" => 110}),
      op("cancel_group", "target", %{"occurred_on" => "2028-02-01"})
    ])

    assert %{"available_cents" => 110, "lots" => [%{"expires_on" => "2028-02-01"}]} =
             credit("2028-02-01")

    assert ledger("2028-02-01")["credit_liability_cents"] == 110
    assert ledger("2028-02-02")["credit_liability_cents"] == 0
  end

  test "unusable read dates are rejected" do
    for path <- ["ledger", "guests/guest/credit"] do
      assert build_conn() |> get("/api/v1/#{path}?on=bad") |> json_response(422) == %{
               "error" => %{"code" => "invalid_date"}
             }
    end
  end
end
