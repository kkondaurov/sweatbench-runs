defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.Repo
  alias GroupStay.Reservations.{CreditAllocation, CreditLot, Group}

  defp batch(operations) do
    build_conn()
    |> post("/api/v1/partner-batches", %{operations: operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open(id, options \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{id}",
        "type" => "open_group",
        "group_id" => id,
        "guest_id" => "guest",
        "property_id" => "hotel",
        "occurred_on" => "2026-12-31",
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 100_000}]
      },
      options
    )
  end

  defp op(type, id, options) do
    Map.merge(
      %{
        "operation_id" => "#{type}-#{id}-#{System.unique_integer([:positive])}",
        "type" => type,
        "group_id" => id,
        "occurred_on" => "2027-01-01"
      },
      options
    )
  end

  defp read(path),
    do: build_conn() |> get("/api/v1/" <> path) |> json_response(200) |> Map.fetch!("data")

  defp credit(on), do: read("guests/guest/credit?on=#{on}")
  defp ledger(on), do: read("ledger?on=#{on}")

  defp issue(id, amount, on, source \\ nil) do
    batch([
      open(id),
      op("record_cash_payment", id, %{"amount_cents" => amount}),
      op("cancel_group", id, %{
        "refund_method" => "hotel_credit",
        "occurred_on" => on,
        "operation_id" => source || "cancel-#{id}"
      })
    ])
  end

  defp fresh_operation(operation),
    do: Map.put(operation, "operation_id", "op-#{System.unique_integer([:positive])}")

  defp snapshot do
    {Repo.all(Group), Repo.all(CreditLot), Repo.all(CreditAllocation)}
  end

  test "policy cutoff and inclusive deadlines remain fixed across rescheduling" do
    for {id, booked, plan, version, deadline} <- [
          {"old", "2026-12-31", "flexible", "flex-14", "2027-05-18"},
          {"new", "2027-01-01", "flexible", "flex-30", "2027-05-02"},
          {"advance", "2026-12-31", "advance_purchase", "advance-nonrefundable", nil}
        ] do
      batch([open(id, %{"occurred_on" => booked, "rate_plan" => plan})])

      assert %{"policy_version" => ^version, "refundable_until" => ^deadline} =
               read("groups/#{id}")

      assert [
               %{
                 "policy_version" => ^version,
                 "refundable_until" => moved,
                 "revision" => 2,
                 "new_departure_on" => "2028-03-02"
               }
             ] =
               batch([
                 op("reschedule_group", id, %{
                   "new_arrival_on" => "2028-03-01",
                   "occurred_on" => "2027-02-01"
                 })
               ])

      expected_deadline =
        case version do
          "flex-14" -> "2028-02-16"
          "flex-30" -> "2028-01-31"
          _ -> nil
        end

      assert moved == expected_deadline
    end

    for {id, booked, date, refund} <- [
          {"old-edge", "2026-12-31", "2027-05-18", 100},
          {"old-late", "2026-12-31", "2027-05-19", 0},
          {"new-edge", "2027-01-01", "2027-05-02", 100},
          {"new-late", "2027-01-01", "2027-05-03", 0}
        ] do
      assert [_, _, %{"refunded_cents" => ^refund, "credit_issued_cents" => 0}] =
               batch([
                 open(id, %{"occurred_on" => booked}),
                 op("record_cash_payment", id, %{"amount_cents" => 100}),
                 op("cancel_group", id, %{"occurred_on" => date})
               ])
    end
  end

  test "credit issuance rounds bonus half upward and expires the day after its deadline" do
    assert [
             _,
             _,
             %{
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 6,
               "revision" => 3
             }
           ] = issue("source", 5, "2027-01-01")

    assert credit("2028-01-01") == %{
             "guest_id" => "guest",
             "available_cents" => 6,
             "lots" => [
               %{
                 "source_operation_id" => "cancel-source",
                 "remaining_cents" => 6,
                 "expires_on" => "2028-01-01"
               }
             ]
           }

    assert ledger("2028-01-01") == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 5,
             "credit_liability_cents" => 6
           }

    assert credit("2028-01-02")["lots"] == []
    assert ledger("2028-01-02")["credit_liability_cents"] == 0
    assert credit("2028-01-01")["available_cents"] == 6
    assert read("guests/unknown/credit")["available_cents"] == 0
    assert read("guests/guest/credit") == credit(Date.utc_today())
    assert read("ledger") == ledger(Date.utc_today())
  end

  test "redemption uses expiry then source ID, pauses expiry and restores original lots without bonus" do
    issue("later", 100, "2027-01-02", "a-later")
    issue("second", 100, "2027-01-01", "z-second")
    issue("first", 100, "2027-01-01", "a-first")

    assert Enum.map(credit("2027-02-01")["lots"], & &1["source_operation_id"]) ==
             ["a-first", "z-second", "a-later"]

    assert [_, %{"amount_cents" => 150, "revision" => 2, "outstanding_deposit_cents" => 19850}] =
             batch([
               open("target"),
               op("apply_hotel_credit", "target", %{
                 "amount_cents" => 150,
                 "expected_revision" => 1
               })
             ])

    assert %{"deposit_paid_cents" => 150, "cash_paid_cents" => 0, "credit_paid_cents" => 150} =
             read("groups/target")

    assert Enum.map(
             credit("2027-02-01")["lots"],
             &{&1["source_operation_id"], &1["remaining_cents"]}
           ) ==
             [{"z-second", 70}, {"a-later", 110}]

    assert ledger("2027-02-01")["credit_liability_cents"] == 330
    assert ledger("2028-01-03")["credit_liability_cents"] == 150
    assert ledger("2027-02-01")["cash_held_cents"] == 0

    assert [%{"credit_issued_cents" => 0, "refunded_cents" => 0, "retained_cents" => 0}] =
             batch([op("cancel_group", "target", %{"refund_method" => "hotel_credit"})])

    assert Enum.map(credit("2027-02-01")["lots"], & &1["remaining_cents"]) == [110, 110, 110]
    assert ledger("2027-02-01")["credit_liability_cents"] == 330
    assert Repo.all(CreditAllocation) == []
  end

  test "expired restored credit disappears while unexpired portions return" do
    issue("old", 100, "2027-01-01")
    issue("young", 100, "2027-01-10")

    batch([
      open("target", %{"arrival_on" => "2028-06-01", "departure_on" => "2028-06-02"}),
      op("apply_hotel_credit", "target", %{"amount_cents" => 150})
    ])

    assert ledger("2028-01-02")["credit_liability_cents"] == 220
    batch([op("cancel_group", "target", %{"occurred_on" => "2028-01-02"})])
    assert credit("2028-01-02")["available_cents"] == 110
    assert ledger("2028-01-02")["credit_liability_cents"] == 110
    assert Repo.all(CreditAllocation) == []
  end

  test "mixed funding settles cash independently and credit never earns another bonus" do
    for {id, method, date, refund, retain, issued, liability} <- [
          {"cash", "cash", "2027-01-01", 50, 0, 0, 110},
          {"credit", "hotel_credit", "2027-01-01", 0, 0, 55, 165},
          {"late", "cash", "2027-05-19", 0, 50, 0, 10}
        ] do
      guest = "guest-#{id}"

      batch([
        open("source-#{id}", %{"guest_id" => guest}),
        op("record_cash_payment", "source-#{id}", %{"amount_cents" => 100}),
        op("cancel_group", "source-#{id}", %{"refund_method" => "hotel_credit"}),
        open(id, %{"guest_id" => guest}),
        op("apply_hotel_credit", id, %{"amount_cents" => 100}),
        op("record_cash_payment", id, %{"amount_cents" => 50})
      ])

      assert %{"deposit_paid_cents" => 150, "cash_paid_cents" => 50, "credit_paid_cents" => 100} =
               read("groups/#{id}")

      assert [
               %{
                 "credit_issued_cents" => ^issued,
                 "refunded_cents" => ^refund,
                 "retained_cents" => ^retain,
                 "revision" => 4
               }
             ] =
               batch([
                 op("cancel_group", id, %{"refund_method" => method, "occurred_on" => date})
               ])

      assert read("guests/#{guest}/credit?on=2027-06-01")["available_cents"] == liability
    end

    assert ledger("2027-06-01") == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 50,
             "cash_retained_cents" => 50,
             "cash_converted_to_credit_cents" => 350,
             "credit_liability_cents" => 285
           }
  end

  test "credit rejection validation is atomic and revisions precede domain rules" do
    issue("source", 100, "2027-01-01")

    batch([
      open("target"),
      open("other", %{"guest_id" => "other"}),
      open("advance", %{"rate_plan" => "advance_purchase"})
    ])

    before = snapshot()

    for {operation, code} <- [
          {op("apply_hotel_credit", "target", %{"amount_cents" => 111}), "insufficient_credit"},
          {op("apply_hotel_credit", "other", %{"amount_cents" => 1}), "insufficient_credit"},
          {op("apply_hotel_credit", "target", %{
             "amount_cents" => 1,
             "occurred_on" => "2028-01-02"
           }), "insufficient_credit"},
          {op("apply_hotel_credit", "target", %{"amount_cents" => 20001}),
           "payment_exceeds_outstanding"},
          {op("cancel_group", "target", %{"refund_method" => "invalid"}),
           "invalid_refund_method"},
          {op("cancel_group", "target", %{"refund_method" => nil}), "invalid_refund_method"},
          {op("cancel_group", "target", %{
             "refund_method" => "hotel_credit",
             "occurred_on" => "2027-05-19"
           }), "refund_method_not_available"},
          {op("cancel_group", "advance", %{"refund_method" => "hotel_credit"}),
           "refund_method_not_available"}
        ] do
      assert [%{"status" => "rejected", "code" => ^code}] = batch([operation])
      assert snapshot() == before

      assert [%{"code" => "stale_revision", "actual_revision" => 1}] =
               batch([fresh_operation(Map.put(operation, "expected_revision", 0))])

      assert snapshot() == before

      assert [%{"code" => "group_not_found"}] =
               batch([fresh_operation(Map.put(operation, "group_id", "missing"))])
    end

    for amount <- [nil, true, 0, -1, "1", 1.5] do
      assert [%{"code" => "invalid_amount"}] =
               batch([op("apply_hotel_credit", "target", %{"amount_cents" => amount})])

      assert snapshot() == before
    end

    assert [%{"code" => "insufficient_credit"}, %{"revision" => 2}, %{"revision" => 3}] =
             batch([
               op("apply_hotel_credit", "target", %{
                 "amount_cents" => 111,
                 "expected_revision" => 1
               }),
               op("apply_hotel_credit", "target", %{
                 "amount_cents" => 110,
                 "expected_revision" => 1,
                 "occurred_on" => "2028-01-01"
               }),
               op("cancel_group", "target", %{"expected_revision" => 2})
             ])

    assert [%{"code" => "group_not_active"}] =
             batch([op("apply_hotel_credit", "target", %{"amount_cents" => 1})])
  end

  test "unfunded cancellations do not create empty lots and malformed read dates are rejected" do
    assert [_, %{"credit_issued_cents" => 0}] =
             batch([
               open("empty"),
               op("cancel_group", "empty", %{"refund_method" => "hotel_credit"})
             ])

    assert Repo.all(CreditLot) == []

    for path <- ["ledger", "guests/guest/credit"], date <- ["bad", "2027-02-29", ""] do
      assert build_conn() |> get("/api/v1/#{path}", %{"on" => date}) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_date"}}
    end
  end
end
