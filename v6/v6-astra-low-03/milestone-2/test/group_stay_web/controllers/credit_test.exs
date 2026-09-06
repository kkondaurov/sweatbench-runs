defmodule GroupStayWeb.CreditTest do
  use GroupStayWeb.ConnCase

  defp op(type, id, date, attrs) do
    Map.merge(
      %{
        "operation_id" => "#{type}-#{id}",
        "type" => type,
        "group_id" => id,
        "occurred_on" => date
      },
      attrs
    )
  end

  defp open(id, booked \\ "2027-01-01", attrs \\ %{}) do
    op(
      "open_group",
      id,
      booked,
      Map.merge(
        %{
          "guest_id" => "guest",
          "property_id" => "hotel",
          "arrival_on" => "2028-06-01",
          "departure_on" => "2028-06-02",
          "rate_plan" => "flexible",
          "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10000}]
        },
        attrs
      )
    )
  end

  defp batch(ops),
    do:
      build_conn()
      |> post("/api/v1/partner-batches", %{operations: ops})
      |> json_response(200)
      |> Map.fetch!("results")

  defp read(path),
    do: build_conn() |> get("/api/v1/" <> path) |> json_response(200) |> Map.fetch!("data")

  defp cash(id, amount),
    do: op("record_cash_payment", id, "2027-01-01", %{"amount_cents" => amount})

  defp cancel(id, date, attrs \\ %{}), do: op("cancel_group", id, date, attrs)

  defp issue(id, date, amount) do
    batch([open(id), cash(id, amount), cancel(id, date, %{"refund_method" => "hotel_credit"})])
  end

  test "same-batch credit is visible only to its guest and inactive groups reject redemption" do
    results =
      batch([
        open("source"),
        cash("source", 100),
        cancel("source", "2027-01-01", %{"refund_method" => "hotel_credit"}),
        open("other", "2027-01-01", %{"guest_id" => "other-guest"}),
        op("apply_hotel_credit", "other", "2027-01-01", %{"amount_cents" => 110}),
        open("target"),
        op("apply_hotel_credit", "target", "2027-01-01", %{
          "amount_cents" => 110,
          "expected_revision" => 1
        }),
        cancel("target", "2027-01-01"),
        op("apply_hotel_credit", "target", "2027-01-01", %{"amount_cents" => 1}),
        op("apply_hotel_credit", "missing", "2027-01-01", %{"expected_revision" => 99})
      ])

    assert Enum.at(results, 4)["code"] == "insufficient_credit"
    assert Enum.at(results, 6)["revision"] == 2
    assert Enum.at(results, 6)["outstanding_deposit_cents"] == 1890
    assert Enum.at(results, 8)["code"] == "group_not_active"
    assert Enum.at(results, 9)["code"] == "group_not_found"
    assert read("guests/guest/credit?on=2027-01-01")["available_cents"] == 110
  end

  test "empty credit settlement creates no lot and read dates validate input" do
    [_, result] =
      batch([open("empty"), cancel("empty", "2027-01-01", %{"refund_method" => "hotel_credit"})])

    assert result["credit_issued_cents"] == 0
    assert read("guests/guest/credit")["lots"] == []
    assert read("ledger")["credit_liability_cents"] == 0

    for path <- ["ledger?on=bad", "guests/guest/credit?on[]=2027-01-01"] do
      assert build_conn() |> get("/api/v1/" <> path) |> json_response(422) == %{
               "error" => %{"code" => "invalid_date"}
             }
    end
  end

  test "policy boundary is fixed across rescheduling and cancellation is inclusive" do
    batch([
      open("old", "2026-12-31"),
      open("new"),
      open("advance", "2027-01-01", %{"rate_plan" => "advance_purchase"})
    ])

    assert read("groups/old")["policy_version"] == "flex-14"
    assert read("groups/new")["refundable_until"] == "2028-05-02"
    assert read("groups/advance")["refundable_until"] == nil

    [moved] =
      batch([op("reschedule_group", "old", "2027-02-01", %{"new_arrival_on" => "2028-07-01"})])

    assert moved["policy_version"] == "flex-14"
    assert moved["refundable_until"] == "2028-06-17"
    batch([cash("new", 100), cash("old", 100)])
    [late, boundary] = batch([cancel("old", "2028-06-18"), cancel("new", "2028-05-02")])
    assert late["retained_cents"] == 100
    assert boundary["refunded_cents"] == 100
  end

  test "bonus rounds half upward and expiry reads are inclusive and nonmutating" do
    assert List.last(issue("source", "2027-01-01", 105))["credit_issued_cents"] == 116
    assert read("guests/guest/credit?on=2028-01-01")["available_cents"] == 116
    assert read("guests/guest/credit?on=2028-01-02")["lots"] == []
    assert read("guests/guest/credit?on=2028-01-01")["available_cents"] == 116
    assert read("guests/unknown/credit")["available_cents"] == 0

    assert read("ledger?on=2028-01-01") == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 105,
             "credit_liability_cents" => 116
           }

    assert read("ledger?on=2028-01-02")["credit_liability_cents"] == 0
  end

  test "redemption pauses expiry and refundable cancellation restores only unexpired allocations" do
    issue("a", "2027-01-01", 100)
    issue("b", "2027-02-01", 100)

    batch([
      open("target"),
      cash("target", 50),
      op("apply_hotel_credit", "target", "2027-03-01", %{"amount_cents" => 150})
    ])

    group = read("groups/target")
    assert group["cash_paid_cents"] == 50
    assert group["credit_paid_cents"] == 150
    assert group["deposit_paid_cents"] == 200
    assert read("ledger?on=2028-01-02")["credit_liability_cents"] == 220
    [result] = batch([cancel("target", "2028-01-02")])
    assert result["refunded_cents"] == 50
    assert result["credit_issued_cents"] == 0

    assert read("guests/guest/credit?on=2028-01-02")["lots"] == [
             %{
               "source_operation_id" => "cancel_group-b",
               "remaining_cents" => 110,
               "expires_on" => "2028-02-01"
             }
           ]

    assert read("ledger?on=2028-01-02")["credit_liability_cents"] == 110
  end

  test "equal expiries use source identifier and credit receives no second bonus" do
    issue("z", "2027-01-01", 100)
    issue("a", "2027-01-01", 100)

    batch([
      open("target"),
      op("apply_hotel_credit", "target", "2027-01-01", %{"amount_cents" => 120}),
      cash("target", 100)
    ])

    assert read("guests/guest/credit?on=2027-01-01")["lots"] == [
             %{
               "source_operation_id" => "cancel_group-z",
               "remaining_cents" => 100,
               "expires_on" => "2028-01-01"
             }
           ]

    [result] = batch([cancel("target", "2027-02-01", %{"refund_method" => "hotel_credit"})])
    assert result["credit_issued_cents"] == 110
    assert read("ledger?on=2027-02-01")["credit_liability_cents"] == 330
    assert read("guests/guest/credit?on=2027-02-01")["available_cents"] == 330
  end

  test "rejections are atomic, revision precedes domain rules, and nonrefundable credit is consumed" do
    issue("source", "2027-01-01", 100)
    batch([open("target", "2027-01-01", %{"rate_plan" => "advance_purchase"})])

    for {attrs, code} <- [
          {%{"amount_cents" => 0}, "invalid_amount"},
          {%{"amount_cents" => 10001}, "payment_exceeds_outstanding"},
          {%{"amount_cents" => 111}, "insufficient_credit"},
          {%{"amount_cents" => 1, "expected_revision" => 99}, "stale_revision"}
        ] do
      [result] = batch([op("apply_hotel_credit", "target", "2027-01-01", attrs)])
      assert result["code"] == code
      assert read("groups/target")["revision"] == 1
      assert read("guests/guest/credit?on=2027-01-01")["available_cents"] == 110
    end

    [expired] = batch([op("apply_hotel_credit", "target", "2028-01-02", %{"amount_cents" => 1})])
    assert expired["code"] == "insufficient_credit"

    batch([
      op("apply_hotel_credit", "target", "2028-01-01", %{"amount_cents" => 110}),
      cash("target", 100)
    ])

    [stale, unavailable, invalid, settled] =
      batch([
        cancel("target", "2028-01-01", %{
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        }),
        cancel("target", "2028-01-01", %{"refund_method" => "hotel_credit"}),
        cancel("target", "2028-01-01", %{"refund_method" => "other"}),
        cancel("target", "2028-01-01", %{"expected_revision" => 3})
      ])

    assert stale["code"] == "stale_revision"
    assert unavailable["code"] == "refund_method_not_available"
    assert invalid["code"] == "invalid_operation"
    assert settled["revision"] == 4
    assert settled["retained_cents"] == 100
    assert read("ledger?on=2028-01-01")["credit_liability_cents"] == 0
  end
end
