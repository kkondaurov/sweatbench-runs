defmodule GroupStayWeb.DepositTransferTest do
  use GroupStayWeb.ConnCase

  defp op(type, attrs) do
    Map.merge(
      %{
        "operation_id" => "op-#{System.unique_integer([:positive])}",
        "type" => type,
        "occurred_on" => "2026-10-01"
      },
      attrs
    )
  end

  defp open(id, attrs \\ %{}) do
    op(
      "open_group",
      Map.merge(
        %{
          "group_id" => id,
          "guest_id" => "guest",
          "property_id" => id,
          "arrival_on" => "2028-12-01",
          "departure_on" => "2028-12-02",
          "rate_plan" => "flexible",
          "rooms" => for(id <- ~w(a b c), do: %{"room_id" => id, "nightly_rate_cents" => 500})
        },
        attrs
      )
    )
  end

  defp submit(ops) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => List.wrap(ops)})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp apply!(operation) do
    [result] = submit(operation)
    assert result["status"] == "applied", inspect(result)
    result
  end

  defp read(path),
    do: build_conn() |> get("/api/v1/" <> path) |> json_response(200) |> Map.fetch!("data")

  defp group(id), do: read("groups/" <> id)
  defp ledger, do: read("ledger?on=2026-10-01")
  defp payment(id), do: read("payments/" <> id)

  defp transfer(amount, attrs \\ %{}),
    do:
      op(
        "transfer_deposit",
        Map.merge(
          %{
            "source_group_id" => "source",
            "destination_group_id" => "destination",
            "amount_cents" => amount
          },
          attrs
        )
      )

  defp cash(id, amount, group \\ "source"),
    do:
      op("record_cash_payment", %{
        "operation_id" => id,
        "group_id" => group,
        "amount_cents" => amount
      })

  test "mixed funding moves newest first, preserves draw order and expiry, and retries exactly" do
    apply!(open("issuer"))
    apply!(cash("credit-principal", 100, "issuer"))
    apply!(op("cancel_group", %{"group_id" => "issuer", "refund_method" => "hotel_credit"}))
    apply!(open("source"))
    apply!(open("destination"))
    original = apply!(cash("pay", 100))
    apply!(op("apply_hotel_credit", %{"group_id" => "source", "amount_cents" => 110}))
    apply!(cash("newest", 50))
    before = ledger()

    move =
      transfer(180, %{
        "expected_revision" => 4,
        "destination_expected_revision" => 1,
        "occurred_on" => "2028-01-01"
      })

    result = apply!(move)

    assert result == %{
             "operation_id" => move["operation_id"],
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 180,
             "source_outstanding_deposit_cents" => 220,
             "destination_outstanding_deposit_cents" => 120,
             "source_revision" => 5,
             "destination_revision" => 2
           }

    assert ledger() == before

    assert Enum.map(
             group("destination")["rooms"],
             &{&1["cash_paid_cents"], &1["credit_paid_cents"]}
           ) == [{50, 50}, {20, 60}, {0, 0}]

    assert payment("pay")["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 20},
             %{"group_id" => "source", "amount_cents" => 80}
           ]

    assert submit(move) == [result]
    assert submit(cash("pay", 100)) == [original]
    # The return transfer draws the newly moved oldest cash first.
    apply!(
      transfer(30, %{"source_group_id" => "destination", "destination_group_id" => "source"})
    )

    assert group("source")["cash_paid_cents"] == 100
    assert group("source")["credit_paid_cents"] == 10
    # Returning expired applied credit restores no availability and creates no bonus.
    apply!(op("cancel_group", %{"group_id" => "destination", "occurred_on" => "2028-01-01"}))
    assert read("guests/guest/credit?on=2028-01-01")["available_cents"] == 0
    assert read("ledger?on=2028-01-01")["credit_liability_cents"] == 10
  end

  test "reductions follow allocation order across groups with overlapping room identifiers" do
    apply!(open("source"))
    apply!(open("destination"))
    apply!(cash("pay", 250))
    apply!(transfer(120))

    reduction =
      op("reduce_cash_payment", %{
        "payment_operation_id" => "pay",
        "amount_cents" => 140,
        "expected_revision" => 3
      })

    result = apply!(reduction)
    assert result["revision"] == 4
    assert result["outstanding_deposit_cents"] == 190
    assert group("destination")["revision"] == 3
    assert group("destination")["cash_paid_cents"] == 0
    assert Enum.map(group("source")["rooms"], & &1["cash_paid_cents"]) == [100, 10, 0]
    assert payment("pay")["held_by_group"] == [%{"group_id" => "source", "amount_cents" => 110}]
    assert ledger()["cash_reduced_cents"] == 140
    assert submit(reduction) == [result]
    apply!(op("charge_back_payment", %{"payment_operation_id" => "pay"}))
    assert group("source")["revision"] == 5
    assert group("destination")["revision"] == 3
    assert payment("pay")["held_by_group"] == []
    assert ledger()["cash_charged_back_cents"] == 110
  end

  test "destination policy settles transferred cash and chargeback updates settlement owners once" do
    apply!(open("source"))
    apply!(open("destination"))
    apply!(open("retained", %{"rate_plan" => "advance_purchase"}))
    apply!(cash("pay", 300))
    apply!(transfer(100))
    apply!(transfer(100, %{"destination_group_id" => "retained"}))
    apply!(op("cancel_group", %{"group_id" => "retained"}))
    apply!(op("cancel_group", %{"group_id" => "destination", "refund_method" => "hotel_credit"}))
    apply!(open("credit-user"))
    apply!(op("apply_hotel_credit", %{"group_id" => "credit-user", "amount_cents" => 110}))
    before = group("credit-user")

    result =
      apply!(
        op("charge_back_payment", %{"payment_operation_id" => "pay", "expected_revision" => 4})
      )

    assert result["revision"] == 5
    assert result["charged_back_cents"] == 300
    assert group("destination")["revision"] == 4
    assert group("retained")["revision"] == 4
    assert group("credit-user") == before
    assert ledger()["cash_retained_cents"] == 0
    assert ledger()["cash_converted_to_credit_cents"] == 0
    assert ledger()["credit_shortfall_cents"] == 110
    assert ledger()["credit_liability_cents"] == 110

    apply!(
      transfer(110, %{"source_group_id" => "credit-user", "destination_group_id" => "source"})
    )

    apply!(op("cancel_group", %{"group_id" => "source"}))
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
  end

  test "validation precedence, atomic rejections, durable conflicts and same-batch guards" do
    apply!(open("source"))
    apply!(open("destination"))
    apply!(open("other", %{"guest_id" => "other"}))
    apply!(open("cancelled"))
    apply!(op("cancel_group", %{"group_id" => "cancelled"}))
    apply!(cash("pay", 100))

    for {attrs, code, id} <- [
          {%{"source_group_id" => "missing", "destination_group_id" => "absent"},
           "group_not_found", "missing"},
          {%{"destination_group_id" => "absent", "expected_revision" => 0}, "group_not_found",
           "absent"},
          {%{"expected_revision" => 0, "destination_expected_revision" => 0}, "stale_revision",
           "source"},
          {%{"destination_expected_revision" => 0, "amount_cents" => -1}, "stale_revision",
           "destination"},
          {%{"destination_group_id" => "source"}, "invalid_transfer", nil},
          {%{"destination_group_id" => "other"}, "invalid_transfer", nil},
          {%{"destination_group_id" => "cancelled"}, "group_not_active", "cancelled"},
          {%{"source_group_id" => "cancelled"}, "group_not_active", "cancelled"},
          {%{"amount_cents" => 0}, "invalid_amount", nil},
          {%{"amount_cents" => 1.5}, "invalid_amount", nil},
          {%{"amount_cents" => 101}, "transfer_exceeds_held_funding", nil}
        ] do
      before = {group("source"), group("destination"), ledger(), payment("pay")}
      operation = transfer(1, attrs)
      [rejection] = submit(operation)
      assert rejection["code"] == code
      if id, do: assert(rejection["group_id"] == id)
      assert submit(operation) == [rejection]
      assert {group("source"), group("destination"), ledger(), payment("pay")} == before
    end

    refute Map.has_key?(payment("pay"), "held_by_group")
    apply!(cash("destination-pay", 300, "destination"))
    assert [%{"code" => "transfer_exceeds_outstanding"}] = submit(transfer(1))

    apply!(
      op("reduce_cash_payment", %{
        "payment_operation_id" => "destination-pay",
        "amount_cents" => 100
      })
    )

    first = transfer(50, %{"expected_revision" => 2, "destination_expected_revision" => 3})
    second = transfer(50, %{"expected_revision" => 3, "destination_expected_revision" => 4})
    assert [%{"source_revision" => 3}, %{"source_revision" => 4}] = submit([first, second])
    assert [%{"code" => "operation_id_conflict"}] = submit(Map.put(first, "amount_cents", 1))
  end

  test "corrections guard and revise the cancelled original group while removing remote cash" do
    apply!(open("source"))
    apply!(open("destination"))
    original = apply!(cash("pay", 100))
    apply!(transfer(100))
    apply!(op("cancel_group", %{"group_id" => "source"}))
    assert group("source")["revision"] == 4

    assert [%{"code" => "stale_revision", "group_id" => "source", "actual_revision" => 4}] =
             submit(
               op("reduce_cash_payment", %{
                 "payment_operation_id" => "pay",
                 "amount_cents" => 10,
                 "expected_revision" => 3
               })
             )

    result =
      apply!(
        op("reduce_cash_payment", %{
          "payment_operation_id" => "pay",
          "amount_cents" => 10,
          "expected_revision" => 4
        })
      )

    assert result["revision"] == 5
    assert result["outstanding_deposit_cents"] == 0
    assert group("destination")["revision"] == 3

    result =
      apply!(
        op("charge_back_payment", %{"payment_operation_id" => "pay", "expected_revision" => 5})
      )

    assert result["revision"] == 6
    assert result["outstanding_deposit_cents"] == 0
    assert result["charged_back_cents"] == 90
    assert group("destination")["revision"] == 4
    assert group("destination")["cash_paid_cents"] == 0
    assert payment("pay")["held_by_group"] == []
    assert submit(cash("pay", 100)) == [original]
  end

  test "converted transfers assign rounded entitlements in destination funding order" do
    apply!(open("source"))
    apply!(open("destination"))
    apply!(cash("older", 5))
    apply!(cash("newer", 5))
    apply!(transfer(10))

    result =
      apply!(
        op("cancel_group", %{"group_id" => "destination", "refund_method" => "hotel_credit"})
      )

    assert result["credit_issued_cents"] == 11
    # The newer payment was drawn first and funded the destination first.
    apply!(op("charge_back_payment", %{"payment_operation_id" => "newer"}))
    assert read("guests/guest/credit?on=2026-10-01")["available_cents"] == 5
    apply!(op("charge_back_payment", %{"payment_operation_id" => "older"}))
    assert ledger()["credit_liability_cents"] == 0
    assert ledger()["cash_charged_back_cents"] == 10
  end
end
