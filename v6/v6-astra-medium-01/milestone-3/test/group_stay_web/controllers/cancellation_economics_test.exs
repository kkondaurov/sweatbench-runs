defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  # Earlier scenarios describe distinct attempts, each now needs its own identifier.
  defp fresh_id(base) do
    count = Process.get({:operation_sequence, base}, 0)
    Process.put({:operation_sequence, base}, count + 1)
    if count == 0, do: base, else: "#{base}-#{count}"
  end

  defp opening(id, attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => fresh_id("open-#{id}"),
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
        "operation_id" => fresh_id("#{type}-#{id}"),
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
    do: build_conn() |> get("/api/v1" <> path) |> json_response(200) |> Map.fetch!("data")

  defp credit(on \\ "2027-05-02"), do: read("/guests/guest/credit?on=#{on}")
  defp ledger(on \\ "2027-05-02"), do: read("/ledger?on=#{on}")

  defp issue(id, amount, on \\ "2027-05-02", source \\ nil) do
    [_, _, result] =
      batch([
        opening(id),
        op("record_cash_payment", id, %{"amount_cents" => amount}),
        op("cancel_group", id, %{
          "refund_method" => "hotel_credit",
          "occurred_on" => on,
          "operation_id" => source || "cancel-#{id}"
        })
      ])

    assert result["status"] == "applied"
    result
  end

  test "booking date fixes the policy, rescheduling recomputes only its cutoff" do
    for {id, booked, plan, policy, cutoff} <- [
          {"old", "2026-12-31", "flexible", "flex-14", "2027-05-18"},
          {"new", "2027-01-01", "flexible", "flex-30", "2027-05-02"},
          {"advance", "2027-01-01", "advance_purchase", "advance-nonrefundable", nil}
        ] do
      batch([opening(id, %{"occurred_on" => booked, "rate_plan" => plan})])
      group = read("/groups/#{id}")
      assert group["policy_version"] == policy
      assert group["refundable_until"] == cutoff

      [moved] =
        batch([
          op("reschedule_group", id, %{
            "occurred_on" => "2028-01-01",
            "new_arrival_on" => "2028-03-01"
          })
        ])

      assert moved["policy_version"] == policy
      assert moved["new_departure_on"] == "2028-03-02"

      expected_cutoff =
        case policy do
          "flex-14" -> "2028-02-16"
          "flex-30" -> "2028-01-31"
          _ -> nil
        end

      assert moved["refundable_until"] == expected_cutoff
      assert read("/groups/#{id}")["refundable_until"] == moved["refundable_until"]
    end
  end

  test "30-day cash refund boundary is inclusive and hotel credit cannot bypass either policy" do
    for {id, date, plan, refund} <- [
          {"early", "2027-05-01", "flexible", 100},
          {"boundary", "2027-05-02", "flexible", 100},
          {"late", "2027-05-03", "flexible", 0},
          {"advance", "2027-01-01", "advance_purchase", 0}
        ] do
      batch([
        opening(id, %{"rate_plan" => plan}),
        op("record_cash_payment", id, %{"amount_cents" => 100})
      ])

      if refund == 0 do
        before = {read("/groups/#{id}"), ledger(), credit()}

        assert [%{"code" => "refund_method_not_available"}] =
                 batch([
                   op("cancel_group", id, %{
                     "occurred_on" => date,
                     "refund_method" => "hotel_credit",
                     "expected_revision" => 2
                   })
                 ])

        assert {read("/groups/#{id}"), ledger(), credit()} == before
      end

      assert [result] = batch([op("cancel_group", id, %{"occurred_on" => date})])
      assert result["refunded_cents"] == refund
      assert result["retained_cents"] == 100 - refund
      assert result["credit_issued_cents"] == 0
      assert result["revision"] == 3
    end
  end

  test "bonus rounds half upward, expiry is inclusive, reads default to UTC and do not mutate" do
    for {id, cash, issued} <- [{"a", 4, 4}, {"b", 5, 6}, {"c", 6, 7}, {"zero", 0, 0}] do
      result =
        if cash == 0 do
          [_, result] =
            batch([opening(id), op("cancel_group", id, %{"refund_method" => "hotel_credit"})])

          result
        else
          issue(id, cash)
        end

      assert result["credit_issued_cents"] == issued
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
    end

    assert credit("2028-05-01")["available_cents"] == 17
    assert credit("2028-05-02")["available_cents"] == 0
    assert credit("2028-05-02")["lots"] == []

    assert ledger("2028-05-01") == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 15,
             "credit_liability_cents" => 17
           }

    assert ledger("2028-05-02")["credit_liability_cents"] == 0
    assert credit()["available_cents"] == 17
    assert read("/guests/guest/credit") == credit(Date.to_iso8601(Date.utc_today()))
    assert read("/ledger") == ledger(Date.to_iso8601(Date.utc_today()))
    assert read("/guests/unknown/credit")["lots"] == []

    for path <- ["/ledger", "/guests/guest/credit"], bad <- ["bad", "2027-02-30", ""] do
      assert build_conn() |> get("/api/v1#{path}?on=#{bad}") |> json_response(422) == %{
               "error" => %{"code" => "invalid_date"}
             }
    end
  end

  test "redemption consumes earliest expiry then source identifier and restores original lots without bonus" do
    issue("z", 100, "2027-05-02", "z")
    issue("b", 100, "2027-05-01", "b")
    issue("a", 100, "2027-05-01", "a")
    assert Enum.map(credit()["lots"], & &1["source_operation_id"]) == ["a", "b", "z"]

    assert [_, applied, paid] =
             batch([
               opening("target"),
               op("apply_hotel_credit", "target", %{
                 "amount_cents" => 150,
                 "expected_revision" => 1
               }),
               op("record_cash_payment", "target", %{
                 "amount_cents" => 50,
                 "expected_revision" => 2
               })
             ])

    assert applied["revision"] == 2
    assert applied["outstanding_deposit_cents"] == 1850
    assert paid["outstanding_deposit_cents"] == 1800

    assert Enum.map(credit()["lots"], &{&1["source_operation_id"], &1["remaining_cents"]}) == [
             {"b", 70},
             {"z", 110}
           ]

    group = read("/groups/target")

    assert {group["cash_paid_cents"], group["credit_paid_cents"], group["deposit_paid_cents"]} ==
             {50, 150, 200}

    assert ledger()["credit_liability_cents"] == 330
    assert ledger()["cash_held_cents"] == 50

    assert [
             %{
               "credit_issued_cents" => 55,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "revision" => 4
             }
           ] =
             batch([
               op("cancel_group", "target", %{
                 "refund_method" => "hotel_credit",
                 "expected_revision" => 3
               })
             ])

    assert credit()["available_cents"] == 385

    assert Enum.take(credit()["lots"], 2) == [
             %{
               "source_operation_id" => "a",
               "remaining_cents" => 110,
               "expires_on" => "2028-04-30"
             },
             %{
               "source_operation_id" => "b",
               "remaining_cents" => 110,
               "expires_on" => "2028-04-30"
             }
           ]

    assert ledger()["cash_converted_to_credit_cents"] == 350
    assert ledger()["credit_liability_cents"] == 385
  end

  test "cash refunds restore credit, repeated allocations restore fully, credit-only cancellation issues no new lot" do
    issue("source", 100)

    batch([
      opening("target"),
      op("apply_hotel_credit", "target", %{"amount_cents" => 20}),
      op("apply_hotel_credit", "target", %{"amount_cents" => 30}),
      op("record_cash_payment", "target", %{"amount_cents" => 25})
    ])

    assert [%{"refunded_cents" => 25, "credit_issued_cents" => 0}] =
             batch([op("cancel_group", "target")])

    assert credit()["available_cents"] == 110
    batch([opening("other"), op("apply_hotel_credit", "other", %{"amount_cents" => 110})])
    assert credit()["lots"] == []

    assert [%{"credit_issued_cents" => 0}] =
             batch([op("cancel_group", "other", %{"refund_method" => "hotel_credit"})])

    assert length(credit()["lots"]) == 1
    assert credit()["available_cents"] == 110
    assert ledger()["cash_refunded_cents"] == 25
  end

  test "expiry is paused while applied, and restoration after expiry extinguishes the allocation" do
    issue("source", 100)

    batch([
      opening("target", %{"arrival_on" => "2028-07-01", "departure_on" => "2028-07-02"}),
      op("apply_hotel_credit", "target", %{"amount_cents" => 60, "occurred_on" => "2028-05-01"})
    ])

    assert credit("2028-05-01")["available_cents"] == 50
    assert ledger("2028-05-01")["credit_liability_cents"] == 110
    assert credit("2028-05-02")["available_cents"] == 0
    assert ledger("2028-05-02")["credit_liability_cents"] == 60

    assert [%{"credit_issued_cents" => 0, "refunded_cents" => 0}] =
             batch([
               op("cancel_group", "target", %{
                 "occurred_on" => "2028-05-02",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert ledger("2028-05-02")["credit_liability_cents"] == 0
    assert credit("2028-05-02")["lots"] == []
  end

  test "restoration on expiry day remains available and nonrefundable settlements consume credit" do
    issue("source", 100)

    batch([
      opening("target", %{"arrival_on" => "2028-07-01", "departure_on" => "2028-07-02"}),
      op("apply_hotel_credit", "target", %{"amount_cents" => 110}),
      op("cancel_group", "target", %{"occurred_on" => "2028-05-01"})
    ])

    assert credit("2028-05-01")["available_cents"] == 110

    for {id, plan, date} <- [
          {"late", "flexible", "2027-05-03"},
          {"advance", "advance_purchase", "2027-05-02"}
        ] do
      batch([
        opening(id, %{"rate_plan" => plan}),
        op("apply_hotel_credit", id, %{"amount_cents" => 50}),
        op("record_cash_payment", id, %{"amount_cents" => 25})
      ])

      assert [%{"refunded_cents" => 0, "retained_cents" => 25, "credit_issued_cents" => 0}] =
               batch([
                 op("cancel_group", id, %{"occurred_on" => date})
               ])
    end

    assert credit()["available_cents"] == 10
    assert ledger()["credit_liability_cents"] == 10
    assert ledger()["cash_retained_cents"] == 50
  end

  test "credit validations are atomic, guest scoped, revision aware and do not stop the batch" do
    issue("source", 100)
    batch([opening("target"), opening("stranger", %{"guest_id" => "someone-else"})])
    before = {read("/groups/target"), credit(), ledger()}

    for {attrs, code} <- [
          {%{"amount_cents" => 0}, "invalid_amount"},
          {%{"amount_cents" => -1}, "invalid_amount"},
          {%{"amount_cents" => 1.0}, "invalid_amount"},
          {%{"amount_cents" => "1"}, "invalid_amount"},
          {%{"amount_cents" => nil}, "invalid_amount"},
          {%{"amount_cents" => true}, "invalid_amount"},
          {%{"amount_cents" => 2001}, "payment_exceeds_outstanding"},
          {%{"amount_cents" => 111}, "insufficient_credit"},
          {%{"amount_cents" => 1, "occurred_on" => "2028-05-02"}, "insufficient_credit"},
          {%{"amount_cents" => 1, "group_id" => "stranger"}, "insufficient_credit"}
        ] do
      assert [%{"code" => ^code}] = batch([op("apply_hotel_credit", "target", attrs)])
      assert {read("/groups/target"), credit(), ledger()} == before
    end

    for operation <- [
          op("apply_hotel_credit", "target", %{"amount_cents" => 111}),
          op("cancel_group", "target", %{"refund_method" => "bad"}),
          op("cancel_group", "target", %{
            "refund_method" => "hotel_credit",
            "occurred_on" => "2027-05-03"
          })
        ] do
      assert [%{"code" => "stale_revision", "actual_revision" => 1}] =
               batch([Map.put(operation, "expected_revision", 0)])

      assert [%{"code" => "group_not_found"}] =
               batch([
                 Map.merge(operation, %{
                   "group_id" => "missing",
                   "expected_revision" => 0,
                   "operation_id" => operation["operation_id"] <> "-missing"
                 })
               ])

      assert {read("/groups/target"), credit(), ledger()} == before
    end

    for method <- ["bad", nil, 42] do
      assert [%{"code" => "invalid_operation"}] =
               batch([op("cancel_group", "target", %{"refund_method" => method})])

      assert {read("/groups/target"), credit(), ledger()} == before
    end

    assert [%{"revision" => 2}, %{"code" => "stale_revision"}, %{"revision" => 3}] =
             batch([
               op("apply_hotel_credit", "target", %{
                 "amount_cents" => 50,
                 "expected_revision" => 1
               }),
               op("apply_hotel_credit", "target", %{"amount_cents" => 1, "expected_revision" => 1}),
               op("apply_hotel_credit", "target", %{
                 "amount_cents" => 60,
                 "expected_revision" => 2
               })
             ])

    batch([op("cancel_group", "target")])

    assert [%{"code" => "group_not_active"}] =
             batch([op("apply_hotel_credit", "target", %{"amount_cents" => 1})])

    assert [%{"code" => "stale_revision"}] =
             batch([
               op("apply_hotel_credit", "target", %{"amount_cents" => 1, "expected_revision" => 3})
             ])
  end

  test "one batch issues credit and funds a later reservation, sharing the deposit limit with cash" do
    [_, _, issued, _, applied, rejected, paid, overpaid] =
      batch([
        opening("source"),
        op("record_cash_payment", "source", %{"amount_cents" => 100}),
        op("cancel_group", "source", %{"refund_method" => "hotel_credit"}),
        opening("target"),
        op("apply_hotel_credit", "target", %{"amount_cents" => 100}),
        op("record_cash_payment", "target", %{"amount_cents" => 1901}),
        op("record_cash_payment", "target", %{"amount_cents" => 1900}),
        op("apply_hotel_credit", "target", %{"amount_cents" => 1})
      ])

    assert issued["credit_issued_cents"] == 110
    assert applied["outstanding_deposit_cents"] == 1900
    assert rejected["code"] == "payment_exceeds_outstanding"
    assert paid["outstanding_deposit_cents"] == 0
    assert paid["revision"] == 3
    assert overpaid["code"] == "payment_exceeds_outstanding"
    assert ledger()["cash_held_cents"] == 1900
    assert ledger()["credit_liability_cents"] == 110
    assert credit()["available_cents"] == 10
  end

  test "restoring mixed expiries releases only unexpired allocations" do
    issue("early", 100, "2027-05-01")
    issue("later", 100, "2027-05-02")

    batch([
      opening("target", %{"arrival_on" => "2028-07-01", "departure_on" => "2028-07-02"}),
      op("apply_hotel_credit", "target", %{"amount_cents" => 200})
    ])

    assert ledger("2028-05-01")["credit_liability_cents"] == 220
    batch([op("cancel_group", "target", %{"occurred_on" => "2028-05-01"})])

    assert credit("2028-05-01") == %{
             "guest_id" => "guest",
             "available_cents" => 110,
             "lots" => [
               %{
                 "source_operation_id" => "cancel-later",
                 "remaining_cents" => 110,
                 "expires_on" => "2028-05-01"
               }
             ]
           }

    assert ledger("2028-05-01")["credit_liability_cents"] == 110
    assert ledger("2028-05-02")["credit_liability_cents"] == 0
  end
end
