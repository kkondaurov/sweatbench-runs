defmodule GroupStayWeb.CreditTest do
  use GroupStayWeb.ConnCase
  alias GroupStay.{Repo, Group, CreditLot, CreditAllocation}

  defp op(type, group, attrs \\ %{}) do
    Map.merge(
      %{
        "type" => type,
        "group_id" => group,
        "operation_id" => "#{type}-#{group}-#{System.unique_integer([:positive])}",
        "occurred_on" => "2027-01-01"
      },
      attrs
    )
  end

  defp open(id, attrs \\ %{}) do
    op(
      "open_group",
      id,
      Map.merge(
        %{
          "guest_id" => "guest",
          "property_id" => "hotel",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-02",
          "rate_plan" => "flexible",
          "rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 100_000}]
        },
        attrs
      )
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

  defp credit(on), do: read("guests/guest/credit?on=#{on}")
  defp ledger(on), do: read("ledger?on=#{on}")

  defp issue(id, amount, date \\ "2027-01-01") do
    [_, _, result] =
      batch([
        open(id),
        op("record_cash_payment", id, %{"amount_cents" => amount}),
        op("cancel_group", id, %{
          "occurred_on" => date,
          "refund_method" => "hotel_credit",
          "operation_id" => id
        })
      ])

    assert result["status"] == "applied"
    result
  end

  defp snapshot, do: Enum.map([Group, CreditLot, CreditAllocation], &Repo.all/1)

  test "policy versions and inclusive windows remain fixed after rescheduling" do
    for {id, booked, plan, policy, cutoff} <- [
          {"old", "2026-12-31", "flexible", "flex-14", "2027-05-18"},
          {"new", "2027-01-01", "flexible", "flex-30", "2027-05-02"},
          {"advance", "2026-12-31", "advance_purchase", "advance-nonrefundable", nil}
        ] do
      batch([open(id, %{"occurred_on" => booked, "rate_plan" => plan})])
      group = read("groups/#{id}")
      assert group["policy_version"] == policy
      assert group["refundable_until"] == cutoff
      [moved] = batch([op("reschedule_group", id, %{"new_arrival_on" => "2028-06-01"})])
      assert moved["policy_version"] == policy
      assert moved["new_departure_on"] == "2028-06-02"

      assert moved["refundable_until"] ==
               if(cutoff, do: String.replace(cutoff, "2027", "2028"), else: nil)
    end

    for {id, date, refund} <- [{"boundary", "2027-05-02", 5}, {"late", "2027-05-03", 0}] do
      [_, _, result] =
        batch([
          open(id),
          op("record_cash_payment", id, %{"amount_cents" => 5}),
          op("cancel_group", id, %{"occurred_on" => date})
        ])

      assert result["refunded_cents"] == refund
      assert result["retained_cents"] == 5 - refund
      assert result["credit_issued_cents"] == 0
    end
  end

  test "cash conversion rounds the bonus and reads use inclusive expiry without mutating lots" do
    assert issue("bonus", 5)["credit_issued_cents"] == 6
    assert issue("down", 4)["credit_issued_cents"] == 4

    assert credit("2028-01-01") == %{
             "guest_id" => "guest",
             "available_cents" => 10,
             "lots" => [
               %{
                 "source_operation_id" => "bonus",
                 "remaining_cents" => 6,
                 "expires_on" => "2028-01-01"
               },
               %{
                 "source_operation_id" => "down",
                 "remaining_cents" => 4,
                 "expires_on" => "2028-01-01"
               }
             ]
           }

    assert ledger("2028-01-01") == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 9,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 10
           }

    before = snapshot()
    assert credit("2028-01-02")["lots"] == []
    assert ledger("2028-01-02")["credit_liability_cents"] == 0
    assert snapshot() == before
    assert credit("2028-01-01")["available_cents"] == 10
    assert read("guests/unknown/credit")["lots"] == []
    assert read("guests/guest/credit") == credit(Date.to_iso8601(Date.utc_today()))
    assert read("ledger") == ledger(Date.to_iso8601(Date.utc_today()))
  end

  test "lots consume by expiry then identifier and refundable mixed funding restores without a second bonus" do
    issue("z", 100)
    issue("a", 100)
    issue("earlier", 100, "2026-12-31")

    [_, paid, applied] =
      batch([
        open("target"),
        op("record_cash_payment", "target", %{"amount_cents" => 5}),
        op("apply_hotel_credit", "target", %{"amount_cents" => 150, "expected_revision" => 2})
      ])

    assert paid["revision"] == 2
    assert applied["revision"] == 3
    assert applied["outstanding_deposit_cents"] == 19845

    assert Enum.map(
             credit("2027-01-01")["lots"],
             &{&1["source_operation_id"], &1["remaining_cents"]}
           ) == [{"a", 70}, {"z", 110}]

    group = read("groups/target")
    assert group["deposit_paid_cents"] == 155
    assert group["credit_paid_cents"] == 150
    assert group["cash_paid_cents"] == 5
    assert ledger("2027-01-01")["credit_liability_cents"] == 330

    [result] =
      batch([
        op("cancel_group", "target", %{
          "refund_method" => "hotel_credit",
          "expected_revision" => 3
        })
      ])

    assert result["credit_issued_cents"] == 6
    assert result["refunded_cents"] == 0
    assert result["retained_cents"] == 0
    assert result["revision"] == 4
    assert credit("2027-01-01")["available_cents"] == 336
    assert ledger("2027-01-01")["credit_liability_cents"] == 336
    assert Repo.all(CreditAllocation) == []
  end

  test "applied expiry pauses and expired restoration removes liability" do
    issue("source", 100)

    batch([
      open("target", %{"arrival_on" => "2028-06-01", "departure_on" => "2028-06-02"}),
      op("apply_hotel_credit", "target", %{"amount_cents" => 60, "occurred_on" => "2028-01-01"}),
      op("record_cash_payment", "target", %{"amount_cents" => 25})
    ])

    assert credit("2028-01-02")["available_cents"] == 0
    assert ledger("2028-01-02")["credit_liability_cents"] == 60
    [result] = batch([op("cancel_group", "target", %{"occurred_on" => "2028-01-02"})])
    assert result["refunded_cents"] == 25
    assert result["credit_issued_cents"] == 0
    assert ledger("2028-01-02")["credit_liability_cents"] == 0
    assert credit("2028-01-02")["available_cents"] == 0
  end

  test "cash refund restores unexpired credit and late cancellation consumes credit" do
    issue("source", 100)

    for {id, date, available, liability, refund, retained} <- [
          {"refundable", "2027-05-02", 110, 110, 25, 0},
          {"late", "2027-05-03", 50, 50, 0, 25}
        ] do
      [_, _, _, result] =
        batch([
          open(id),
          op("apply_hotel_credit", id, %{"amount_cents" => 60}),
          op("record_cash_payment", id, %{"amount_cents" => 25}),
          op("cancel_group", id, %{"occurred_on" => date})
        ])

      assert result["refunded_cents"] == refund
      assert result["retained_cents"] == retained
      assert credit(date)["available_cents"] == available
      assert ledger(date)["credit_liability_cents"] == liability
    end
  end

  test "all credit and refund rejections preserve state and revision and allow later operations" do
    issue("source", 100)

    batch([
      open("target"),
      open("other", %{"guest_id" => "other"}),
      open("advance", %{"rate_plan" => "advance_purchase"})
    ])

    cases = [
      {op("apply_hotel_credit", "missing", %{"expected_revision" => 99}), "group_not_found"},
      {op("apply_hotel_credit", "target", %{"expected_revision" => 0}), "stale_revision"},
      {op("cancel_group", "target", %{"expected_revision" => 0, "refund_method" => "bad"}),
       "stale_revision"},
      {op("apply_hotel_credit", "target"), "invalid_operation"},
      {op("apply_hotel_credit", "target", %{"amount_cents" => 0}), "invalid_amount"},
      {op("apply_hotel_credit", "target", %{"amount_cents" => -1}), "invalid_amount"},
      {op("apply_hotel_credit", "target", %{"amount_cents" => 1.0}), "invalid_amount"},
      {op("apply_hotel_credit", "target", %{"amount_cents" => 20001}),
       "payment_exceeds_outstanding"},
      {op("apply_hotel_credit", "target", %{"amount_cents" => 111}), "insufficient_credit"},
      {op("apply_hotel_credit", "other", %{"amount_cents" => 1}), "insufficient_credit"},
      {op("apply_hotel_credit", "target", %{"amount_cents" => 1, "occurred_on" => "2028-01-02"}),
       "insufficient_credit"},
      {op("cancel_group", "target", %{"refund_method" => "bad"}), "invalid_operation"},
      {op("cancel_group", "target", %{
         "refund_method" => "hotel_credit",
         "occurred_on" => "2027-05-03"
       }), "refund_method_not_available"},
      {op("cancel_group", "advance", %{"refund_method" => "hotel_credit"}),
       "refund_method_not_available"}
    ]

    for {operation, code} <- cases do
      before = snapshot()
      assert [%{"code" => ^code}] = batch([operation])
      assert snapshot() == before
    end

    assert [
             %{"revision" => 2},
             %{"code" => "stale_revision"},
             %{"revision" => 3},
             %{"code" => "group_not_active"}
           ] =
             batch([
               op("apply_hotel_credit", "target", %{
                 "amount_cents" => 110,
                 "expected_revision" => 1
               }),
               op("cancel_group", "target", %{"expected_revision" => 1}),
               op("cancel_group", "target", %{"expected_revision" => 2}),
               op("apply_hotel_credit", "target", %{"amount_cents" => 1})
             ])
  end

  test "invalid read dates return a controlled error" do
    for path <- ["ledger?on=bad", "guests/guest/credit?on=2027-02-30", "ledger?on[]=bad"] do
      assert build_conn() |> get("/api/v1/" <> path) |> json_response(422) == %{
               "error" => %{"code" => "invalid_date"}
             }
    end
  end

  test "restoration on the expiry date remains available and unpaid conversion creates no lot" do
    issue("source", 100)

    batch([
      open("target", %{"arrival_on" => "2028-06-01", "departure_on" => "2028-06-02"}),
      op("apply_hotel_credit", "target", %{"amount_cents" => 110}),
      op("cancel_group", "target", %{"occurred_on" => "2028-01-01"})
    ])

    assert credit("2028-01-01")["available_cents"] == 110
    assert ledger("2028-01-02")["credit_liability_cents"] == 0
    before = Repo.all(CreditLot)

    assert [_, %{"credit_issued_cents" => 0, "revision" => 2}] =
             batch([
               open("unpaid"),
               op("cancel_group", "unpaid", %{"refund_method" => "hotel_credit"})
             ])

    assert Repo.all(CreditLot) == before
  end
end
