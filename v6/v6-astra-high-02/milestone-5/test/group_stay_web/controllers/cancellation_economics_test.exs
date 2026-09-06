defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{CreditAllocation, CreditLot, Group, Repo}

  defp opening(id, attrs \\ %{}) do
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

  defp op(type, id, attrs) do
    Map.merge(
      %{
        "operation_id" => "#{type}-#{id}-#{System.unique_integer([:positive])}",
        "type" => type,
        "group_id" => id,
        "occurred_on" => "2027-05-02"
      },
      attrs
    )
  end

  defp batch(ops) do
    build_conn()
    |> post(~p"/api/v1/partner-batches", %{"operations" => ops})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp read(path), do: build_conn() |> get(path) |> json_response(200) |> Map.fetch!("data")
  defp group(id), do: read("/api/v1/groups/#{id}")
  defp credit(on \\ "2027-05-02"), do: read("/api/v1/guests/guest/credit?on=#{on}")
  defp ledger(on \\ "2027-05-02"), do: read("/api/v1/ledger?on=#{on}")
  defp snapshot, do: {Repo.all(Group), Repo.all(CreditLot), Repo.all(CreditAllocation)}

  defp issue(id, amount, on \\ "2027-05-02", source \\ nil) do
    batch([
      opening(id),
      op("record_cash_payment", id, %{"amount_cents" => amount}),
      op("cancel_group", id, %{
        "refund_method" => "hotel_credit",
        "occurred_on" => on,
        "operation_id" => source || "cancel-#{id}"
      })
    ])
  end

  test "policy is selected at booking and fixed through moves across the policy change" do
    for {id, booked, policy, cutoff} <- [
          {"old", "2026-12-31", "flex-14", "2027-05-18"},
          {"new", "2027-01-01", "flex-30", "2027-05-02"}
        ] do
      batch([opening(id, %{"occurred_on" => booked})])
      assert %{"policy_version" => ^policy, "refundable_until" => ^cutoff} = group(id)

      assert [
               %{
                 "policy_version" => ^policy,
                 "refundable_until" => moved_cutoff,
                 "new_departure_on" => "2028-03-02",
                 "revision" => 2
               }
             ] =
               batch([
                 op("reschedule_group", id, %{
                   "occurred_on" => "2028-01-01",
                   "new_arrival_on" => "2028-03-01"
                 })
               ])

      assert moved_cutoff == if(id == "old", do: "2028-02-16", else: "2028-01-31")
      assert group(id)["booked_on"] == booked
      assert group(id)["refundable_until"] == moved_cutoff
    end

    batch([opening("advance", %{"rate_plan" => "advance_purchase"})])

    assert %{"policy_version" => "advance-nonrefundable", "refundable_until" => nil} =
             group("advance")
  end

  test "new flexible cutoff is inclusive and advance purchase remains non-refundable" do
    for {id, plan, on, refunded, retained} <- [
          {"early", "flexible", "2027-05-01", 100, 0},
          {"boundary", "flexible", "2027-05-02", 100, 0},
          {"late", "flexible", "2027-05-03", 0, 100},
          {"advance", "advance_purchase", "2027-01-01", 0, 100}
        ] do
      assert [
               _,
               _,
               %{
                 "refunded_cents" => ^refunded,
                 "retained_cents" => ^retained,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ] =
               batch([
                 opening(id, %{"rate_plan" => plan}),
                 op("record_cash_payment", id, %{"amount_cents" => 100}),
                 op("cancel_group", id, %{"occurred_on" => on})
               ])
    end

    assert %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 200,
             "cash_retained_cents" => 200,
             "credit_liability_cents" => 0
           } = ledger()
  end

  test "cash conversion rounds the bonus half upward and expires after its inclusive anniversary" do
    for {id, cash, issued} <- [{"below", 4, 4}, {"half", 5, 6}, {"above", 6, 7}] do
      assert [
               _,
               _,
               %{
                 "credit_issued_cents" => ^issued,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "revision" => 3
               }
             ] = issue(id, cash)
    end

    assert %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 15,
             "credit_liability_cents" => 17
           } = ledger()

    assert credit("2028-05-01")["available_cents"] == 17
    assert Enum.all?(credit()["lots"], &(&1["expires_on"] == "2028-05-01"))
    assert credit("2028-05-02") == %{"guest_id" => "guest", "available_cents" => 0, "lots" => []}
    assert ledger("2028-05-02")["credit_liability_cents"] == 0
    assert ledger("2028-05-02")["cash_converted_to_credit_cents"] == 15
    assert credit()["available_cents"] == 17
  end

  test "lots are consumed by expiry then exact source identifier and restored without a bonus" do
    issue("later", 100, "2027-05-02", "A-later")
    issue("z", 100, "2027-05-01", "Z")
    issue("a", 100, "2027-05-01", "A")
    assert Enum.map(credit()["lots"], & &1["source_operation_id"]) == ["A", "Z", "A-later"]

    assert [_, %{"amount_cents" => 150, "outstanding_deposit_cents" => 1850, "revision" => 2}] =
             batch([
               opening("target"),
               op("apply_hotel_credit", "target", %{"amount_cents" => 150})
             ])

    assert credit()["lots"] == [
             %{
               "source_operation_id" => "Z",
               "remaining_cents" => 70,
               "expires_on" => "2028-04-30"
             },
             %{
               "source_operation_id" => "A-later",
               "remaining_cents" => 110,
               "expires_on" => "2028-05-01"
             }
           ]

    assert %{"deposit_paid_cents" => 150, "cash_paid_cents" => 0, "credit_paid_cents" => 150} =
             group("target")

    assert ledger()["credit_liability_cents"] == 330
    assert ledger()["cash_held_cents"] == 0

    assert [%{"credit_issued_cents" => 0, "refunded_cents" => 0, "revision" => 3}] =
             batch([op("cancel_group", "target", %{"refund_method" => "hotel_credit"})])

    assert Enum.map(credit()["lots"], & &1["remaining_cents"]) == [110, 110, 110]

    assert %{"deposit_paid_cents" => 0, "cash_paid_cents" => 0, "credit_paid_cents" => 0} =
             group("target")

    assert ledger()["credit_liability_cents"] == 330
  end

  test "mixed funding refunds only cash or bonuses only cash when converted" do
    for method <- ["cash", "hotel_credit"] do
      guest = "guest-#{method}"
      id = "source-#{method}"

      batch([
        opening(id, %{"guest_id" => guest}),
        op("record_cash_payment", id, %{"amount_cents" => 100}),
        op("cancel_group", id, %{"refund_method" => "hotel_credit"})
      ])

      target = "target-#{method}"

      assert [_, %{"revision" => 2}, %{"outstanding_deposit_cents" => 1895, "revision" => 3}] =
               batch([
                 opening(target, %{"guest_id" => guest}),
                 op("apply_hotel_credit", target, %{"amount_cents" => 100}),
                 op("record_cash_payment", target, %{"amount_cents" => 5})
               ])

      assert ledger()["cash_held_cents"] == 5

      assert [
               %{
                 "refunded_cents" => refunded,
                 "retained_cents" => 0,
                 "credit_issued_cents" => issued,
                 "revision" => 4
               }
             ] =
               batch([op("cancel_group", target, %{"refund_method" => method})])

      assert refunded == if(method == "cash", do: 5, else: 0)
      assert issued == if(method == "hotel_credit", do: 6, else: 0)

      assert read("/api/v1/guests/#{guest}/credit?on=2027-05-02")["available_cents"] ==
               110 + issued
    end

    assert %{
             "cash_refunded_cents" => 5,
             "cash_converted_to_credit_cents" => 205,
             "cash_held_cents" => 0,
             "credit_liability_cents" => 226
           } = ledger()
  end

  test "redeemed expiry is paused and refundable restoration expires only the overdue lots" do
    issue("old", 100, "2027-05-01")
    issue("new", 100, "2027-05-02")

    batch([
      opening("target", %{"arrival_on" => "2028-07-01", "departure_on" => "2028-07-02"}),
      op("apply_hotel_credit", "target", %{"amount_cents" => 150})
    ])

    assert ledger("2028-05-01")["credit_liability_cents"] == 220
    assert ledger("2028-05-02")["credit_liability_cents"] == 150
    assert credit("2028-05-02")["available_cents"] == 0
    batch([op("cancel_group", "target", %{"occurred_on" => "2028-05-01"})])
    assert credit("2028-05-01")["available_cents"] == 110
    assert ledger("2028-05-01")["credit_liability_cents"] == 110
    assert ledger("2028-05-02")["credit_liability_cents"] == 0
    assert Repo.all(CreditAllocation) == []
  end

  test "non-refundable mixed cancellation retains cash and consumes credit even after expiry" do
    issue("source", 100)

    batch([
      opening("target"),
      op("apply_hotel_credit", "target", %{"amount_cents" => 100}),
      op("record_cash_payment", "target", %{"amount_cents" => 50})
    ])

    before = snapshot()

    assert [%{"code" => "refund_method_not_available"}] =
             batch([
               op("cancel_group", "target", %{
                 "occurred_on" => "2028-05-02",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert snapshot() == before

    assert [
             %{
               "refunded_cents" => 0,
               "retained_cents" => 50,
               "credit_issued_cents" => 0,
               "revision" => 4
             }
           ] =
             batch([op("cancel_group", "target", %{"occurred_on" => "2028-05-02"})])

    assert ledger("2028-05-02")["credit_liability_cents"] == 0
    assert credit()["available_cents"] == 10
    assert Repo.all(CreditAllocation) == []
  end

  test "credit validation, guest isolation, stale precedence and failures preserve all tables" do
    issue("source", 100)
    batch([opening("target"), opening("other", %{"guest_id" => "other"})])

    for {type, id, attrs, code} <- [
          {"apply_hotel_credit", "missing", %{"expected_revision" => 99}, "group_not_found"},
          {"apply_hotel_credit", "target", %{"amount_cents" => 111}, "insufficient_credit"},
          {"apply_hotel_credit", "other", %{"amount_cents" => 1}, "insufficient_credit"},
          {"apply_hotel_credit", "target", %{"amount_cents" => 2001},
           "payment_exceeds_outstanding"},
          {"apply_hotel_credit", "target", %{"amount_cents" => 1, "occurred_on" => "2028-05-02"},
           "insufficient_credit"},
          {"apply_hotel_credit", "target", %{}, "invalid_operation"},
          {"apply_hotel_credit", "source", %{"amount_cents" => 1}, "group_not_active"},
          {"apply_hotel_credit", "target", %{"amount_cents" => 111, "expected_revision" => 0},
           "stale_revision"},
          {"cancel_group", "target",
           %{
             "refund_method" => "hotel_credit",
             "occurred_on" => "2027-05-03",
             "expected_revision" => 0
           }, "stale_revision"},
          {"cancel_group", "target", %{"refund_method" => "bogus"}, "invalid_operation"},
          {"cancel_group", "target", %{"refund_method" => nil}, "invalid_operation"}
        ] do
      before = snapshot()
      assert [%{"code" => ^code}] = batch([op(type, id, attrs)])
      assert snapshot() == before
    end

    for amount <- [0, -1, 1.5, "1", nil, true, [], %{}] do
      before = snapshot()

      assert [%{"code" => "invalid_amount"}] =
               batch([op("apply_hotel_credit", "target", %{"amount_cents" => amount})])

      assert snapshot() == before
    end

    assert [
             %{"revision" => 2},
             %{"code" => "stale_revision", "actual_revision" => 2},
             %{"code" => "insufficient_credit"},
             %{"revision" => 3}
           ] =
             batch([
               op("apply_hotel_credit", "target", %{
                 "amount_cents" => 100,
                 "expected_revision" => 1
               }),
               op("apply_hotel_credit", "target", %{"amount_cents" => 1, "expected_revision" => 1}),
               op("apply_hotel_credit", "target", %{
                 "amount_cents" => 11,
                 "expected_revision" => 2
               }),
               op("apply_hotel_credit", "target", %{
                 "amount_cents" => 10,
                 "expected_revision" => 2
               })
             ])

    assert credit()["lots"] == []
  end

  test "unpaid refundable hotel-credit cancellation issues no empty lot" do
    assert [_, %{"credit_issued_cents" => 0, "revision" => 2}] =
             batch([
               opening("unpaid"),
               op("cancel_group", "unpaid", %{"refund_method" => "hotel_credit"})
             ])

    assert Repo.all(CreditLot) == []
  end

  test "credit is immediately usable in a batch and can fund advance purchase without changing its policy" do
    assert [
             _,
             _,
             %{"credit_issued_cents" => 110},
             _,
             %{"revision" => 2},
             %{"code" => "refund_method_not_available"},
             %{"retained_cents" => 0, "revision" => 3}
           ] =
             batch([
               opening("source", %{"occurred_on" => "2026-12-31"}),
               op("record_cash_payment", "source", %{"amount_cents" => 100}),
               op("cancel_group", "source", %{
                 "refund_method" => "hotel_credit",
                 "occurred_on" => "2027-05-18"
               }),
               opening("advance", %{"rate_plan" => "advance_purchase"}),
               op("apply_hotel_credit", "advance", %{
                 "amount_cents" => 110,
                 "occurred_on" => "2027-05-18"
               }),
               op("cancel_group", "advance", %{
                 "refund_method" => "hotel_credit",
                 "expected_revision" => 2,
                 "occurred_on" => "2027-05-18"
               }),
               op("cancel_group", "advance", %{
                 "expected_revision" => 2,
                 "occurred_on" => "2027-05-18"
               })
             ])

    assert group("source")["policy_version"] == "flex-14"
    assert group("advance")["policy_version"] == "advance-nonrefundable"
    assert ledger("2027-05-18")["credit_liability_cents"] == 0
    assert credit("2027-05-18")["available_cents"] == 0
  end

  test "credit can be redeemed on expiry, repeated allocations restore once, and expired restorations are lost" do
    issue("source", 100)
    batch([opening("target", %{"arrival_on" => "2028-07-01", "departure_on" => "2028-07-02"})])

    for amount <- [50, 60] do
      assert [%{"status" => "applied"}] =
               batch([
                 op("apply_hotel_credit", "target", %{
                   "amount_cents" => amount,
                   "occurred_on" => "2028-05-01"
                 })
               ])
    end

    assert ledger("2028-05-02")["credit_liability_cents"] == 110

    assert [%{"credit_issued_cents" => 0, "revision" => 4}] =
             batch([
               op("cancel_group", "target", %{
                 "occurred_on" => "2028-05-02",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert ledger("2028-05-02")["credit_liability_cents"] == 0
    assert credit()["available_cents"] == 0

    issue("second-source", 100)
    batch([opening("second-target")])

    for amount <- [50, 60] do
      batch([op("apply_hotel_credit", "second-target", %{"amount_cents" => amount})])
    end

    batch([op("cancel_group", "second-target", %{})])
    assert credit()["available_cents"] == 110
    assert ledger()["credit_liability_cents"] == 110
    before = snapshot()
    assert [%{"code" => "group_not_active"}] = batch([op("cancel_group", "second-target", %{})])
    assert snapshot() == before
  end

  test "reads default to UTC today, unknown guests are empty, and invalid query dates return 422" do
    today = Date.utc_today()
    arrival = Date.add(today, 60)

    batch([
      opening("today", %{
        "occurred_on" => Date.to_iso8601(today),
        "arrival_on" => Date.to_iso8601(arrival),
        "departure_on" => Date.to_iso8601(Date.add(arrival, 1))
      }),
      op("record_cash_payment", "today", %{
        "amount_cents" => 100,
        "occurred_on" => Date.to_iso8601(today)
      }),
      op("cancel_group", "today", %{
        "refund_method" => "hotel_credit",
        "occurred_on" => Date.to_iso8601(today)
      })
    ])

    assert read("/api/v1/guests/guest/credit") == credit(Date.to_iso8601(today))
    assert read("/api/v1/ledger") == ledger(Date.to_iso8601(today))

    assert read("/api/v1/guests/unknown/credit") == %{
             "guest_id" => "unknown",
             "available_cents" => 0,
             "lots" => []
           }

    for endpoint <- ["/api/v1/ledger", "/api/v1/guests/guest/credit"],
        query <- ["on=bad", "on=2027-02-29", "on[]=2027-01-01"] do
      assert build_conn() |> get("#{endpoint}?#{query}") |> json_response(422) == %{
               "error" => %{"code" => "invalid_date"}
             }
    end
  end
end
