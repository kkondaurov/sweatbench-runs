defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  defp open(id, attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{id}",
        "type" => "open_group",
        "group_id" => id,
        "guest_id" => "guest",
        "property_id" => "hotel",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10000}]
      },
      attrs
    )
  end

  defp op(type, id, attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "#{type}-#{id}",
        "type" => type,
        "group_id" => id,
        "occurred_on" => "2027-05-02"
      },
      attrs
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

  defp credit(on \\ "2027-05-02"), do: read("guests/guest/credit?on=#{on}")
  defp ledger(on \\ "2027-05-02"), do: read("ledger?on=#{on}")

  defp issue(id, amount, attrs \\ %{}) do
    batch([
      open(id),
      op("record_cash_payment", id, %{"amount_cents" => amount}),
      op("cancel_group", id, Map.merge(%{"refund_method" => "hotel_credit"}, attrs))
    ])
  end

  test "policy selection, inclusive cutoffs, and fixed versions across rescheduling" do
    for {id, booked, plan, version, cutoff} <- [
          {"old", "2026-12-31", "flexible", "flex-14", "2027-05-18"},
          {"new", "2027-01-01", "flexible", "flex-30", "2027-05-02"},
          {"advance", "2026-12-31", "advance_purchase", "advance-nonrefundable", nil}
        ] do
      batch([open(id, %{"occurred_on" => booked, "rate_plan" => plan})])
      assert %{"policy_version" => ^version, "refundable_until" => ^cutoff} = read("groups/#{id}")
      [result] = batch([op("reschedule_group", id, %{"new_arrival_on" => "2028-03-01"})])
      assert result["policy_version"] == version
      assert result["new_departure_on"] == "2028-03-02"

      expected_cutoff =
        case version do
          "flex-14" -> "2028-02-16"
          "flex-30" -> "2028-01-31"
          _ -> nil
        end

      assert result["refundable_until"] == expected_cutoff
    end

    for {id, day, refunded} <- [{"boundary", "2027-05-02", 100}, {"late", "2027-05-03", 0}] do
      [_, _, result] =
        batch([
          open(id),
          op("record_cash_payment", id, %{"amount_cents" => 100}),
          op("cancel_group", id, %{"occurred_on" => day})
        ])

      assert result["refunded_cents"] == refunded
      assert result["retained_cents"] == 100 - refunded
    end
  end

  test "credit bonus rounds half upward, expiry is inclusive, and reads do not expire balances" do
    assert [
             _,
             _,
             %{
               "credit_issued_cents" => 116,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "revision" => 3
             }
           ] = issue("source", 105)

    assert credit("2028-05-01")["lots"] == [
             %{
               "source_operation_id" => "cancel_group-source",
               "remaining_cents" => 116,
               "expires_on" => "2028-05-01"
             }
           ]

    assert credit("2028-05-02")["available_cents"] == 0
    assert ledger("2028-05-02")["credit_liability_cents"] == 0
    assert ledger()["credit_liability_cents"] == 116
    assert ledger()["cash_converted_to_credit_cents"] == 105
    assert ledger()["cash_held_cents"] == 0
    assert read("guests/unknown/credit")["lots"] == []
    assert read("guests/guest/credit") == credit(Date.to_iso8601(Date.utc_today()))
    assert read("ledger") == ledger(Date.to_iso8601(Date.utc_today()))
  end

  test "lots redeem by expiry then operation id and refundable mixed funding restores without bonus" do
    issue("z", 100)
    issue("a", 100)
    issue("earlier", 100, %{"occurred_on" => "2027-05-01"})

    batch([
      open("target"),
      op("apply_hotel_credit", "target", %{"amount_cents" => 150}),
      op("record_cash_payment", "target", %{"amount_cents" => 105})
    ])

    assert credit()["lots"] == [
             %{
               "source_operation_id" => "cancel_group-a",
               "remaining_cents" => 70,
               "expires_on" => "2028-05-01"
             },
             %{
               "source_operation_id" => "cancel_group-z",
               "remaining_cents" => 110,
               "expires_on" => "2028-05-01"
             }
           ]

    assert %{
             "cash_paid_cents" => 105,
             "credit_paid_cents" => 150,
             "deposit_paid_cents" => 255,
             "outstanding_deposit_cents" => 1745,
             "revision" => 3
           } = read("groups/target")

    assert ledger()["credit_liability_cents"] == 330
    assert ledger()["cash_held_cents"] == 105

    assert [%{"credit_issued_cents" => 116, "revision" => 4}] =
             batch([op("cancel_group", "target", %{"refund_method" => "hotel_credit"})])

    assert credit()["available_cents"] == 446
    assert ledger()["credit_liability_cents"] == 446
    assert ledger()["cash_converted_to_credit_cents"] == 405
    assert ledger()["cash_refunded_cents"] == 0
  end

  test "cash refund restores original credit and does not refund credit as cash" do
    issue("source", 100)

    batch([
      open("target"),
      op("apply_hotel_credit", "target", %{"amount_cents" => 110}),
      op("record_cash_payment", "target", %{"amount_cents" => 50})
    ])

    assert [%{"refunded_cents" => 50, "retained_cents" => 0, "credit_issued_cents" => 0}] =
             batch([op("cancel_group", "target")])

    assert credit()["available_cents"] == 110
    assert ledger()["cash_refunded_cents"] == 50
  end

  test "allocated credit survives expiry and expired restoration immediately removes liability" do
    issue("source", 100)

    batch([
      open("target", %{"arrival_on" => "2028-08-01", "departure_on" => "2028-08-02"}),
      op("apply_hotel_credit", "target", %{"amount_cents" => 60, "occurred_on" => "2028-05-01"})
    ])

    assert ledger("2028-05-01")["credit_liability_cents"] == 110
    assert ledger("2028-05-02")["credit_liability_cents"] == 60
    assert credit("2028-05-02")["available_cents"] == 0
    batch([op("cancel_group", "target", %{"occurred_on" => "2028-05-02"})])
    assert ledger("2028-05-02")["credit_liability_cents"] == 0
    assert credit("2028-05-02")["lots"] == []
  end

  test "nonrefundable settlements consume credit and retain only cash" do
    issue("source", 100)

    batch([
      open("target"),
      op("apply_hotel_credit", "target", %{"amount_cents" => 110}),
      op("record_cash_payment", "target", %{"amount_cents" => 50})
    ])

    before = {read("groups/target"), ledger(), credit()}

    assert [%{"code" => "refund_method_not_available"}] =
             batch([
               op("cancel_group", "target", %{
                 "occurred_on" => "2027-05-03",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert {read("groups/target"), ledger(), credit()} == before

    assert [%{"retained_cents" => 50, "refunded_cents" => 0, "credit_issued_cents" => 0}] =
             batch([op("cancel_group", "target", %{"occurred_on" => "2027-05-03"})])

    assert ledger()["credit_liability_cents"] == 0
    assert ledger()["cash_retained_cents"] == 50
  end

  test "credit validation and revision precedence leave every account unchanged" do
    issue("source", 100)
    batch([open("target"), open("other", %{"guest_id" => "someone-else"})])

    assert [%{"code" => "insufficient_credit"}] =
             batch([op("apply_hotel_credit", "other", %{"amount_cents" => 1})])

    before = {read("groups/target"), ledger(), credit()}

    for {attrs, code} <- [
          {%{}, "invalid_operation"},
          {%{"amount_cents" => 0}, "invalid_amount"},
          {%{"amount_cents" => -1}, "invalid_amount"},
          {%{"amount_cents" => 1.5}, "invalid_amount"},
          {%{"amount_cents" => "1"}, "invalid_amount"},
          {%{"amount_cents" => nil}, "invalid_amount"},
          {%{"amount_cents" => 2001}, "payment_exceeds_outstanding"},
          {%{"amount_cents" => 111}, "insufficient_credit"},
          {%{"amount_cents" => 1, "occurred_on" => "2028-05-02"}, "insufficient_credit"},
          {%{"amount_cents" => 111, "expected_revision" => 0}, "stale_revision"}
        ] do
      assert [%{"code" => ^code}] = batch([op("apply_hotel_credit", "target", attrs)])
      assert {read("groups/target"), ledger(), credit()} == before
    end

    assert [%{"code" => "invalid_operation"}, %{"code" => "stale_revision"}, %{"revision" => 2}] =
             batch([
               op("cancel_group", "target", %{"refund_method" => "unknown"}),
               op("cancel_group", "target", %{
                 "refund_method" => "unknown",
                 "expected_revision" => 0
               }),
               op("apply_hotel_credit", "target", %{
                 "amount_cents" => 110,
                 "expected_revision" => 1
               })
             ])

    batch([op("cancel_group", "target")])

    assert [
             %{"code" => "group_not_active"},
             %{"code" => "stale_revision"},
             %{"code" => "group_not_found"}
           ] =
             batch([
               op("apply_hotel_credit", "target", %{"amount_cents" => 1}),
               op("apply_hotel_credit", "target", %{"expected_revision" => 1}),
               op("apply_hotel_credit", "missing", %{"expected_revision" => 1})
             ])
  end

  test "invalid read dates return a useful client error" do
    for path <- ["ledger?on=bad", "guests/guest/credit?on=2027-02-30", "ledger?on[]=bad"] do
      assert build_conn() |> get("/api/v1/" <> path) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_date"}}
    end
  end

  test "repeated redemptions restore the same lot on its expiry date" do
    issue("source", 100)

    batch([
      open("target", %{"arrival_on" => "2028-08-01", "departure_on" => "2028-08-02"}),
      op("apply_hotel_credit", "target", %{"amount_cents" => 40}),
      op("apply_hotel_credit", "target", %{"amount_cents" => 70}),
      op("cancel_group", "target", %{
        "occurred_on" => "2028-05-01",
        "refund_method" => "hotel_credit"
      })
    ])

    assert credit("2028-05-01")["available_cents"] == 110
    assert length(credit("2028-05-01")["lots"]) == 1
    assert ledger("2028-05-01")["credit_liability_cents"] == 110
    assert ledger("2028-05-02")["credit_liability_cents"] == 0
  end

  test "unfunded cancellation issues no lot and advance purchase cannot choose credit" do
    assert [_, %{"credit_issued_cents" => 0}] =
             batch([
               open("empty"),
               op("cancel_group", "empty", %{"refund_method" => "hotel_credit"})
             ])

    assert credit()["lots"] == []
    batch([open("advance", %{"rate_plan" => "advance_purchase"})])

    assert [%{"code" => "stale_revision"}, %{"code" => "refund_method_not_available"}] =
             batch([
               op("cancel_group", "advance", %{
                 "refund_method" => "hotel_credit",
                 "expected_revision" => 0
               }),
               op("cancel_group", "advance", %{"refund_method" => "hotel_credit"})
             ])

    assert read("groups/advance")["revision"] == 1
    assert read("groups/advance")["status"] == "active"
  end
end
